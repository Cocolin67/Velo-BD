<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;

/**
 * Locations : emprunt et restitution via les procédures stockées (règles métier,
 * verrous et historisation côté base), consultations par usager et pour l'exploitant.
 */
final class RentalRepository
{
    public function __construct(private readonly Database $db)
    {
    }

    /** Location en cours de l'usager, avec durée écoulée et coût estimé (fn_calculer_cout). */
    public function current(int $idUsager): ?array
    {
        return $this->db->fetchOne(
            'SELECT l.id_location, l.id_velo, l.date_heure_emprunt, v.type_velo, v.niveau_batterie,
                    s.id_station, s.nom AS station_depart,
                    TIMESTAMPDIFF(MINUTE, l.date_heure_emprunt, NOW()) AS minutes,
                    fn_calculer_cout(l.id_abonnement, l.id_velo,
                                     TIMESTAMPDIFF(MINUTE, l.date_heure_emprunt, NOW())) AS cout_estime
               FROM location l
               JOIN abonnement a ON a.id_abonnement = l.id_abonnement
               JOIN velo v       ON v.id_velo       = l.id_velo
               JOIN borne b      ON b.id_borne      = l.id_borne_depart
               JOIN station s    ON s.id_station    = b.id_station
              WHERE a.id_utilisateur = ? AND l.date_heure_restitution IS NULL
              LIMIT 1',
            [$idUsager],
        );
    }

    /** Vélos empruntables dans une station (disponibles, sur une borne fonctionnelle, station en service). */
    public function availableBikes(int $idStation): array
    {
        return $this->db->fetchAll(
            "SELECT v.id_velo, v.type_velo, v.niveau_batterie, b.num_borne
               FROM borne b
               JOIN station s ON s.id_station = b.id_station
               JOIN velo v    ON v.id_borne   = b.id_borne
              WHERE b.id_station = ? AND b.etat_borne = 'fonctionnelle'
                AND s.etat_station = 'en_service' AND v.etat_velo = 'disponible'
              ORDER BY v.type_velo DESC, v.niveau_batterie DESC, b.num_borne",
            [$idStation],
        );
    }

    /** Première borne libre et fonctionnelle d'une station en service. */
    public function freeDock(int $idStation): ?int
    {
        $id = $this->db->fetchValue(
            "SELECT b.id_borne
               FROM borne b
               JOIN station s     ON s.id_station = b.id_station
               LEFT JOIN velo v   ON v.id_borne   = b.id_borne
              WHERE b.id_station = ? AND b.etat_borne = 'fonctionnelle'
                AND s.etat_station = 'en_service' AND v.id_velo IS NULL
              ORDER BY b.num_borne
              LIMIT 1",
            [$idStation],
        );

        return $id === null ? null : (int) $id;
    }

    /** sp_emprunter_velo : abonnement valide, un seul vélo à la fois, vélo disponible. */
    public function borrow(int $idUsager, int $idVelo): int
    {
        return (int) $this->db->call('sp_emprunter_velo', [$idUsager, $idVelo], ['id_location'])['out']['id_location'];
    }

    /**
     * sp_rendre_velo : la durée est calculée par la colonne générée, le coût par trigger.
     *
     * @return array{id_location: int, duree_min: int, cout: string}
     */
    public function giveBack(int $idUsager, int $idBorne): array
    {
        return $this->db->call('sp_rendre_velo', [$idUsager, $idBorne], ['id_location', 'duree_min', 'cout'])['out'];
    }

    /** Totaux des trajets terminés d'un usager. */
    public function summary(int $idUsager): array
    {
        return $this->db->fetchOne(
            'SELECT COUNT(*) AS trajets, COALESCE(SUM(l.duree_min), 0) AS minutes, COALESCE(SUM(l.cout), 0) AS depenses
               FROM location l
               JOIN abonnement a ON a.id_abonnement = l.id_abonnement
              WHERE a.id_utilisateur = ? AND l.date_heure_restitution IS NOT NULL',
            [$idUsager],
        ) ?? ['trajets' => 0, 'minutes' => 0, 'depenses' => 0];
    }

    /** @return array{rows: list<array<string, mixed>>, has_next: bool} */
    public function history(int $idUsager, int $page, int $perPage): array
    {
        $rows = $this->db->fetchAll(
            'SELECT l.id_location, l.id_velo, v.type_velo, l.date_heure_emprunt, l.date_heure_restitution,
                    l.duree_min, l.cout, sd.nom AS station_depart, sa.nom AS station_arrivee
               FROM location l
               JOIN abonnement a  ON a.id_abonnement = l.id_abonnement
               JOIN velo v        ON v.id_velo       = l.id_velo
               JOIN borne bd      ON bd.id_borne     = l.id_borne_depart
               JOIN station sd    ON sd.id_station   = bd.id_station
               LEFT JOIN borne ba   ON ba.id_borne   = l.id_borne_arrivee
               LEFT JOIN station sa ON sa.id_station = ba.id_station
              WHERE a.id_utilisateur = ?
              ORDER BY l.date_heure_emprunt DESC
              LIMIT ? OFFSET ?',
            [$idUsager, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }

    /**
     * Toutes les locations, pour l'exploitant.
     *
     * @param array{statut: ?string, du: string, au: string, station: ?int, type: ?string, q: string} $f
     * @return array{rows: list<array<string, mixed>>, has_next: bool}
     */
    public function search(array $f, int $page, int $perPage): array
    {
        $where  = [];
        $params = [];

        if ($f['statut'] === 'en_cours') {
            // Peu de lignes : servi par l'index unique sur velo_en_cours, sans filtre de date
            $where[] = 'l.velo_en_cours IS NOT NULL';
        } else {
            // Bornes de dates sur date_heure_emprunt : utilise idx_loc_emprunt
            $where[]  = 'l.date_heure_emprunt >= ? AND l.date_heure_emprunt < ? + INTERVAL 1 DAY';
            $params[] = $f['du'];
            $params[] = $f['au'];
            if ($f['statut'] === 'terminees') {
                $where[] = 'l.date_heure_restitution IS NOT NULL';
            }
        }
        if ($f['station'] !== null) {
            $where[]  = 'bd.id_station = ?';
            $params[] = $f['station'];
        }
        if ($f['type'] !== null) {
            $where[]  = 'v.type_velo = ?';
            $params[] = $f['type'];
        }
        if ($f['q'] !== '') {
            $where[]  = '(u.nom LIKE ? OR u.email LIKE ?)';
            $like     = '%' . addcslashes($f['q'], '%_\\') . '%';
            $params[] = $like;
            $params[] = $like;
        }

        $rows = $this->db->fetchAll(
            'SELECT l.id_location, l.date_heure_emprunt, l.date_heure_restitution, l.duree_min, l.cout,
                    l.id_velo, v.type_velo, u.prenom, u.nom, u.email,
                    sd.nom AS station_depart, sa.nom AS station_arrivee
               FROM location l
               JOIN abonnement a    ON a.id_abonnement  = l.id_abonnement
               JOIN utilisateur u   ON u.id_utilisateur = a.id_utilisateur
               JOIN velo v          ON v.id_velo        = l.id_velo
               JOIN borne bd        ON bd.id_borne      = l.id_borne_depart
               JOIN station sd      ON sd.id_station    = bd.id_station
               LEFT JOIN borne ba   ON ba.id_borne      = l.id_borne_arrivee
               LEFT JOIN station sa ON sa.id_station    = ba.id_station
              WHERE ' . implode(' AND ', $where) . '
              ORDER BY l.date_heure_emprunt DESC
              LIMIT ? OFFSET ?',
            [...$params, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }
}
