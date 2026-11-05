<?php

declare(strict_types=1);

namespace App\Database;

use PDO;
use PDOException;
use PDOStatement;

/**
 * Accès à MySQL via PDO : requêtes préparées uniquement, connexion paresseuse
 * et traduction des erreurs SQL en messages lisibles.
 *
 * Les erreurs métier levées par la base (SIGNAL SQLSTATE '45000' dans les
 * triggers et les procédures) deviennent des BusinessException dont le message
 * peut être affiché tel quel à l'utilisateur.
 */
final class Database
{
    private ?PDO $pdo = null;

    /** @param array{host: string, port: int, name: string, user: string, pass: string} $config */
    public function __construct(private readonly array $config)
    {
    }

    public function pdo(): PDO
    {
        if ($this->pdo === null) {
            $c   = $this->config;
            $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $c['host'], $c['port'], $c['name']);

            $this->pdo = new PDO($dsn, $c['user'], $c['pass'], [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                // Vraies requêtes préparées côté serveur : pas d'émulation, types natifs
                PDO::ATTR_EMULATE_PREPARES   => false,
                PDO::ATTR_STRINGIFY_FETCHES  => false,
            ]);
        }

        return $this->pdo;
    }

    /** @return list<array<string, mixed>> */
    public function fetchAll(string $sql, array $params = []): array
    {
        return $this->run($sql, $params)->fetchAll();
    }

    /** @return array<string, mixed>|null */
    public function fetchOne(string $sql, array $params = []): ?array
    {
        $row = $this->run($sql, $params)->fetch();

        return $row === false ? null : $row;
    }

    public function fetchValue(string $sql, array $params = []): mixed
    {
        $value = $this->run($sql, $params)->fetchColumn();

        return $value === false ? null : $value;
    }

    /** Exécute un INSERT / UPDATE / DELETE et renvoie le nombre de lignes touchées. */
    public function execute(string $sql, array $params = []): int
    {
        return $this->run($sql, $params)->rowCount();
    }

    public function lastInsertId(): int
    {
        return (int) $this->pdo()->lastInsertId();
    }

    /**
     * Appelle une procédure stockée.
     *
     * @param string       $procedure nom de la procédure (lettres, chiffres, _)
     * @param list<mixed>  $in        paramètres IN, dans l'ordre
     * @param list<string> $out       noms des paramètres OUT, dans l'ordre (après les IN)
     *
     * @return array{rows: list<list<array<string, mixed>>>, out: array<string, mixed>}
     *         rows : chaque jeu de résultats renvoyé ; out : valeurs des paramètres OUT
     */
    public function call(string $procedure, array $in = [], array $out = []): array
    {
        if (!preg_match('/^[a-z_][a-z0-9_]*$/i', $procedure)) {
            throw new \InvalidArgumentException('Nom de procédure invalide');
        }
        foreach ($out as $name) {
            if (!preg_match('/^[a-z_][a-z0-9_]*$/i', $name)) {
                throw new \InvalidArgumentException('Nom de paramètre OUT invalide');
            }
        }

        $args = array_merge(array_fill(0, count($in), '?'), array_map(static fn ($o) => '@' . $o, $out));
        $stmt = $this->run(sprintf('CALL %s(%s)', $procedure, implode(', ', $args)), $in);

        $rows = [];
        try {
            do {
                if ($stmt->columnCount() > 0) {
                    $rows[] = $stmt->fetchAll();
                }
            } while ($stmt->nextRowset());
        } catch (PDOException $e) {
            throw self::translate($e);
        } finally {
            $stmt->closeCursor();
        }

        $values = [];
        if ($out) {
            $select = implode(', ', array_map(static fn ($o) => sprintf('@%1$s AS %1$s', $o), $out));
            $values = $this->fetchOne('SELECT ' . $select) ?? [];
        }

        return ['rows' => $rows, 'out' => $values];
    }

    /**
     * Exécute $callback dans une transaction (COMMIT si tout va bien, ROLLBACK sinon).
     *
     * @template T
     * @param callable(self): T $callback
     * @return T
     */
    public function transaction(callable $callback): mixed
    {
        $pdo = $this->pdo();
        $pdo->beginTransaction();
        try {
            $result = $callback($this);
            $pdo->commit();

            return $result;
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
            throw $e;
        }
    }

    private function run(string $sql, array $params): PDOStatement
    {
        try {
            $stmt = $this->pdo()->prepare($sql);
            $i    = 1;
            foreach ($params as $value) {
                $stmt->bindValue($i++, $value, match (true) {
                    is_int($value)  => PDO::PARAM_INT,
                    is_bool($value) => PDO::PARAM_BOOL,
                    $value === null => PDO::PARAM_NULL,
                    default         => PDO::PARAM_STR,
                });
            }
            $stmt->execute();

            return $stmt;
        } catch (PDOException $e) {
            throw self::translate($e);
        }
    }

    /** Convertit les erreurs SQL connues en messages compréhensibles par l'utilisateur. */
    private static function translate(PDOException $e): \Throwable
    {
        $code    = (int) ($e->errorInfo[1] ?? 0);
        $message = (string) ($e->errorInfo[2] ?? $e->getMessage());

        return match ($code) {
            // SIGNAL SQLSTATE '45000' : message métier écrit dans les triggers / procédures
            1644    => new BusinessException($message, 0, $e),
            1062    => new BusinessException('Cette valeur est déjà utilisée (doublon).', 0, $e),
            // 1217 / 1216 : variantes de 1451 / 1452 renvoyées quand le compte ne voit pas la table liée
            1451,
            1217    => new BusinessException('Suppression impossible : des données y font référence (historique conservé).', 0, $e),
            1452,
            1216    => new BusinessException('Référence inconnue : l\'élément lié n\'existe pas.', 0, $e),
            3819    => new BusinessException('Données refusées par une contrainte d\'intégrité de la base.', 0, $e),
            1205,
            1213    => new BusinessException('Opération concurrente en cours, merci de réessayer.', 0, $e),
            default => $e,
        };
    }
}
