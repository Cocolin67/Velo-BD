<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;

/** Signalements de problèmes sur un vélo ou une station. */
final class ReportRepository
{
    public const STATUTS = ['ouvert', 'pris_en_charge', 'clos'];

    private const SELECT = 'SELECT sg.id_signalement, sg.date_heure, sg.description, sg.statut,
                                   sg.id_velo, sg.id_station, st.nom AS station, sg.id_intervention,
                                   u.prenom, u.nom
                              FROM signalement sg
                              JOIN utilisateur u   ON u.id_utilisateur = sg.id_utilisateur
                              LEFT JOIN station st ON st.id_station    = sg.id_station';

    public function __construct(private readonly Database $db)
    {
    }

    /** sp_signaler_probleme ; un vélo disponible signalé passe « défectueux » (trigger). */
    public function create(int $idUtilisateur, ?int $idVelo, ?int $idStation, string $description): int
    {
        $r = $this->db->call('sp_signaler_probleme', [$idUtilisateur, $idVelo, $idStation, $description], ['id_signalement']);

        return (int) $r['out']['id_signalement'];
    }

    public function byAuthor(int $idUtilisateur): array
    {
        return $this->db->fetchAll(
            self::SELECT . ' WHERE sg.id_utilisateur = ? ORDER BY sg.date_heure DESC LIMIT 20',
            [$idUtilisateur],
        );
    }

    /**
     * File de traitement des opérateurs (index idx_sig_statut_date).
     *
     * @param array{statut: ?string, cible: ?string} $f
     * @return array{rows: list<array<string, mixed>>, has_next: bool}
     */
    public function search(array $f, int $page, int $perPage): array
    {
        $where  = ['1 = 1'];
        $params = [];
        if ($f['statut'] !== null) {
            $where[]  = 'sg.statut = ?';
            $params[] = $f['statut'];
        }
        if ($f['cible'] === 'velo') {
            $where[] = 'sg.id_velo IS NOT NULL';
        } elseif ($f['cible'] === 'station') {
            $where[] = 'sg.id_station IS NOT NULL';
        }

        // Les plus anciens d'abord pour la file « ouverts », les plus récents sinon
        $order = $f['statut'] === 'ouvert' ? 'ASC' : 'DESC';
        $rows  = $this->db->fetchAll(
            self::SELECT . ' WHERE ' . implode(' AND ', $where) . " ORDER BY sg.date_heure $order LIMIT ? OFFSET ?",
            [...$params, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }

    /** @return array<string, int> nombre de signalements par statut */
    public function countByStatus(): array
    {
        $counts = array_fill_keys(self::STATUTS, 0);
        foreach ($this->db->fetchAll('SELECT statut, COUNT(*) AS n FROM signalement GROUP BY statut') as $r) {
            $counts[$r['statut']] = (int) $r['n'];
        }

        return $counts;
    }

    public function takeCharge(int $id): bool
    {
        return $this->db->execute(
            "UPDATE signalement SET statut = 'pris_en_charge' WHERE id_signalement = ? AND statut = 'ouvert'",
            [$id],
        ) > 0;
    }

    /** sp_cloturer_signalement : remet le vélo en service s'il n'est plus bloqué. */
    public function close(int $id): void
    {
        $this->db->call('sp_cloturer_signalement', [$id]);
    }
}
