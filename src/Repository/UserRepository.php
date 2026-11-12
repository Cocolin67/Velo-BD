<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;
use App\Support\Sort;

/** Requêtes sur UTILISATEUR et ses rôles (USAGER, OPERATEUR, ADMINISTRATEUR). */
final class UserRepository
{
    /** Colonnes triables de la liste des comptes (voir App\Support\Sort) */
    public const SORTABLE = [
        'nom'         => ['u.nom', 'u.prenom'],
        'email'       => 'u.email',
        'role'        => 'role',
        'detail'      => 'COALESCE(o.matricule, us.telephone)',
        'inscription' => 'u.date_inscription',
    ];

    public function __construct(private readonly Database $db)
    {
    }

    /** Hash et rôle d'un compte (procédure sp_authentifier), null si l'email est inconnu. */
    public function findForLogin(string $email): ?array
    {
        return $this->db->call('sp_authentifier', [$email])['rows'][0][0] ?? null;
    }

    /** Inscription d'un usager (sp_inscrire_usager, transactionnelle). Renvoie son identifiant. */
    public function registerUsager(string $nom, string $prenom, string $email, string $hash, ?string $naissance, ?string $telephone): int
    {
        $result = $this->db->call(
            'sp_inscrire_usager',
            [$nom, $prenom, $email, $hash, $naissance, $telephone],
            ['id_utilisateur'],
        );

        return (int) $result['out']['id_utilisateur'];
    }

    public function updatePasswordHash(int $id, string $hash): void
    {
        $this->db->execute('UPDATE utilisateur SET mot_de_passe_hash = ? WHERE id_utilisateur = ?', [$hash, $id]);
    }

    public function findProfile(int $id): ?array
    {
        return $this->db->fetchOne(
            'SELECT u.id_utilisateur, u.nom, u.prenom, u.email, u.date_inscription, u.mot_de_passe_hash,
                    us.telephone, us.date_naissance, o.matricule, o.specialite
               FROM utilisateur u
               LEFT JOIN usager    us ON us.id_utilisateur = u.id_utilisateur
               LEFT JOIN operateur o  ON o.id_utilisateur  = u.id_utilisateur
              WHERE u.id_utilisateur = ?',
            [$id],
        );
    }

    /** Mise à jour du profil (utilisateur + usager) dans une même transaction. */
    public function updateProfile(int $id, string $nom, string $prenom, string $email, bool $isUsager, ?string $telephone, ?string $naissance): void
    {
        $this->db->transaction(function (Database $db) use ($id, $nom, $prenom, $email, $isUsager, $telephone, $naissance): void {
            $db->execute(
                'UPDATE utilisateur SET nom = ?, prenom = ?, email = ? WHERE id_utilisateur = ?',
                [$nom, $prenom, $email, $id],
            );
            if ($isUsager) {
                $db->execute(
                    'UPDATE usager SET telephone = ?, date_naissance = ? WHERE id_utilisateur = ?',
                    [$telephone, $naissance, $id],
                );
            }
        });
    }

    /**
     * Liste des comptes et de leur rôle, pour l'administration.
     *
     * @return array{rows: list<array<string, mixed>>, has_next: bool}
     */
    public function search(string $q, ?string $role, int $page, int $perPage, ?Sort $tri = null): array
    {
        $order  = $tri?->orderBy(self::SORTABLE, 'u.nom, u.prenom', 'u.id_utilisateur', ['detail']) ?? 'u.nom, u.prenom';
        $where  = ['1 = 1'];
        $params = [];
        if ($q !== '') {
            $where[] = '(u.nom LIKE ? OR u.prenom LIKE ? OR u.email LIKE ?)';
            $like    = '%' . addcslashes($q, '%_\\') . '%';
            array_push($params, $like, $like, $like);
        }
        $where[] = match ($role) {
            'usager'         => 'us.id_utilisateur IS NOT NULL',
            'operateur'      => 'o.id_utilisateur IS NOT NULL AND a.id_utilisateur IS NULL',
            'administrateur' => 'a.id_utilisateur IS NOT NULL',
            default          => '1 = 1',
        };

        $rows = $this->db->fetchAll(
            "SELECT u.id_utilisateur, u.nom, u.prenom, u.email, u.date_inscription,
                    CASE WHEN a.id_utilisateur  IS NOT NULL THEN 'administrateur'
                         WHEN o.id_utilisateur  IS NOT NULL THEN 'operateur'
                         WHEN us.id_utilisateur IS NOT NULL THEN 'usager'
                    END AS role,
                    o.matricule, o.specialite, us.telephone
               FROM utilisateur u
               LEFT JOIN usager         us ON us.id_utilisateur = u.id_utilisateur
               LEFT JOIN operateur      o  ON o.id_utilisateur  = u.id_utilisateur
               LEFT JOIN administrateur a  ON a.id_utilisateur  = u.id_utilisateur
              WHERE " . implode(' AND ', $where) . '
              ORDER BY ' . $order . '
              LIMIT ? OFFSET ?',
            [...$params, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }

    /** @return array<string, int> nombre de comptes par rôle */
    public function countByRole(): array
    {
        return $this->db->fetchOne(
            'SELECT (SELECT COUNT(*) FROM usager)                                   AS usager,
                    (SELECT COUNT(*) FROM operateur) - (SELECT COUNT(*) FROM administrateur) AS operateur,
                    (SELECT COUNT(*) FROM administrateur)                           AS administrateur'
        ) ?? [];
    }

    /** sp_creer_operateur : opérateur de régulation / maintenance, éventuellement administrateur. */
    public function createOperator(string $nom, string $prenom, string $email, string $hash, string $matricule, string $specialite, bool $admin): int
    {
        $r = $this->db->call(
            'sp_creer_operateur',
            [$nom, $prenom, $email, $hash, $matricule, $specialite, $admin],
            ['id_utilisateur'],
        );

        return (int) $r['out']['id_utilisateur'];
    }
}
