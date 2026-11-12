<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;
use App\Support\Sort;

/** Flotte de vélos et historiques (alimentés par les triggers trg_velo_ai / trg_velo_au). */
final class BikeRepository
{
    public const ETATS = ['disponible', 'en_location', 'en_atelier', 'defectueux'];
    public const TYPES = ['mecanique', 'electrique'];

    /** Colonnes triables depuis l'en-tête du tableau (voir App\Support\Sort) */
    public const SORTABLE = [
        'velo'     => 'v.id_velo',
        'type'     => 'CAST(v.type_velo AS CHAR)',
        'etat'     => 'CAST(v.etat_velo AS CHAR)',
        'batterie' => 'v.niveau_batterie',
        'position' => ['s.nom', 'b.num_borne'],
        'service'  => 'v.date_mise_en_service',
    ];

    public function __construct(private readonly Database $db)
    {
    }

    /**
     * @param array{id: ?int, type: ?string, etat: ?string, station: ?int, batterie: ?int} $f
     * @return array{rows: list<array<string, mixed>>, has_next: bool}
     */
    public function search(array $f, int $page, int $perPage, ?Sort $tri = null): array
    {
        $where  = ['1 = 1'];
        $params = [];
        if ($f['id'] !== null) {
            $where[]  = 'v.id_velo = ?';
            $params[] = $f['id'];
        }
        if ($f['type'] !== null) {
            $where[]  = 'v.type_velo = ?';
            $params[] = $f['type'];
        }
        if ($f['etat'] !== null) {
            $where[]  = 'v.etat_velo = ?';     // index idx_velo_etat_type
            $params[] = $f['etat'];
        }
        if ($f['station'] !== null) {
            $where[]  = 'b.id_station = ?';
            $params[] = $f['station'];
        }
        if ($f['batterie'] !== null) {
            $where[]  = 'v.niveau_batterie <= ?';
            $params[] = $f['batterie'];
        }

        $rows = $this->db->fetchAll(
            'SELECT v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie, v.date_mise_en_service,
                    s.id_station, s.nom AS station, b.num_borne
               FROM velo v
               LEFT JOIN borne b   ON b.id_borne   = v.id_borne
               LEFT JOIN station s ON s.id_station = b.id_station
              WHERE ' . implode(' AND ', $where) . '
              ORDER BY ' . ($tri?->orderBy(self::SORTABLE, 'v.id_velo', 'v.id_velo', ['batterie', 'position']) ?? 'v.id_velo') . '
              LIMIT ? OFFSET ?',
            [...$params, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }

    /** @return array<string, int> nombre de vélos par état */
    public function countByState(): array
    {
        $counts = array_fill_keys(self::ETATS, 0);
        foreach ($this->db->fetchAll('SELECT etat_velo, COUNT(*) AS n FROM velo GROUP BY etat_velo') as $r) {
            $counts[$r['etat_velo']] = (int) $r['n'];
        }

        return $counts;
    }

    public function find(int $id): ?array
    {
        return $this->db->fetchOne(
            'SELECT v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie, v.date_mise_en_service,
                    s.id_station, s.nom AS station, b.num_borne
               FROM velo v
               LEFT JOIN borne b   ON b.id_borne   = v.id_borne
               LEFT JOIN station s ON s.id_station = b.id_station
              WHERE v.id_velo = ?',
            [$id],
        );
    }

    public function stateHistory(int $id, int $limit = 15): array
    {
        return $this->db->fetchAll(
            'SELECT date_heure, etat_velo FROM historique_etat
              WHERE id_velo = ? ORDER BY date_heure DESC, id_hist_etat DESC LIMIT ?',
            [$id, $limit],
        );
    }

    public function positionHistory(int $id, int $limit = 15): array
    {
        return $this->db->fetchAll(
            'SELECT hp.type_position, hp.date_heure_debut, hp.date_heure_fin, s.nom AS station, b.num_borne
               FROM historique_position hp
               LEFT JOIN borne b   ON b.id_borne   = hp.id_borne
               LEFT JOIN station s ON s.id_station = b.id_station
              WHERE hp.id_velo = ?
              ORDER BY hp.date_heure_debut DESC, hp.id_hist_pos DESC
              LIMIT ?',
            [$id, $limit],
        );
    }

    public function rentals(int $id, int $limit = 10): array
    {
        return $this->db->fetchAll(
            'SELECT l.id_location, l.date_heure_emprunt, l.duree_min, l.cout,
                    sd.nom AS station_depart, sa.nom AS station_arrivee
               FROM location l
               JOIN borne bd        ON bd.id_borne   = l.id_borne_depart
               JOIN station sd      ON sd.id_station = bd.id_station
               LEFT JOIN borne ba   ON ba.id_borne   = l.id_borne_arrivee
               LEFT JOIN station sa ON sa.id_station = ba.id_station
              WHERE l.id_velo = ?
              ORDER BY l.date_heure_emprunt DESC
              LIMIT ?',
            [$id, $limit],
        );
    }

    public function interventions(int $id, int $limit = 10): array
    {
        return $this->db->fetchAll(
            'SELECT i.date_retrait, i.date_remise_circulation, i.description_travaux, u.prenom, u.nom
               FROM intervention i
               JOIN utilisateur u ON u.id_utilisateur = i.id_operateur
              WHERE i.id_velo = ?
              ORDER BY i.date_retrait DESC
              LIMIT ?',
            [$id, $limit],
        );
    }

    public function reports(int $id, int $limit = 10): array
    {
        return $this->db->fetchAll(
            'SELECT id_signalement, date_heure, description, statut FROM signalement
              WHERE id_velo = ? ORDER BY date_heure DESC LIMIT ?',
            [$id, $limit],
        );
    }
}
