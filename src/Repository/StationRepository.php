<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\BusinessException;
use App\Database\Database;

/** Stations, bornes et occupation en temps réel (vue v_stations_occupation). */
final class StationRepository
{
    public const ETATS       = ['en_service', 'hors_service', 'en_travaux'];
    public const ETATS_BORNE = ['fonctionnelle', 'hors_service'];

    private const SORTS = [
        'nom'         => 'o.nom ASC',
        'disponibles' => 'o.nb_velos_disponibles DESC, o.nom ASC',
        'libres'      => 'o.nb_bornes_libres DESC, o.nom ASC',
        'remplissage' => 'o.taux_remplissage DESC, o.nom ASC',
    ];

    public function __construct(private readonly Database $db)
    {
    }

    /**
     * Recherche paginée.
     *
     * @param array{q?: string, etat?: ?string, dispo?: ?string, sort?: ?string} $f
     * @return array{rows: list<array<string, mixed>>, has_next: bool}
     */
    public function search(array $f, int $page, int $perPage): array
    {
        $where  = [];
        $params = [];

        if (($f['q'] ?? '') !== '') {
            $where[]  = '(o.nom LIKE ? OR s.adresse LIKE ?)';
            $like     = '%' . addcslashes($f['q'], '%_\\') . '%';
            $params[] = $like;
            $params[] = $like;
        }
        if (!empty($f['etat'])) {
            $where[]  = 'o.etat_station = ?';
            $params[] = $f['etat'];
        }
        $where[] = match ($f['dispo'] ?? null) {
            'velos'       => 'o.nb_velos_disponibles > 0',
            'electriques' => 'o.nb_velos_electriques > 0',
            'bornes'      => 'o.nb_bornes_libres > 0',
            default       => '1 = 1',
        };

        $order = self::SORTS[$f['sort'] ?? 'nom'] ?? self::SORTS['nom'];
        $rows  = $this->db->fetchAll(
            'SELECT o.id_station, o.nom, s.adresse, o.etat_station, o.nb_bornes, o.nb_bornes_libres,
                    o.nb_velos_mecaniques, o.nb_velos_electriques, o.nb_velos_disponibles, o.taux_remplissage
               FROM v_stations_occupation o
               JOIN station s ON s.id_station = o.id_station
              WHERE ' . implode(' AND ', $where) . '
              ORDER BY ' . $order . '
              LIMIT ? OFFSET ?',
            [...$params, $perPage + 1, ($page - 1) * $perPage],
        );

        return ['rows' => array_slice($rows, 0, $perPage), 'has_next' => count($rows) > $perPage];
    }

    public function find(int $id): ?array
    {
        return $this->db->fetchOne(
            'SELECT s.id_station, s.nom, s.adresse, s.latitude, s.longitude, s.etat_station,
                    o.nb_bornes, o.nb_bornes_libres, o.nb_velos, o.nb_velos_mecaniques,
                    o.nb_velos_electriques, o.nb_velos_disponibles, o.taux_remplissage
               FROM station s
               JOIN v_stations_occupation o ON o.id_station = s.id_station
              WHERE s.id_station = ?',
            [$id],
        );
    }

    /** Bornes d'une station et vélo posé sur chacune. */
    public function bornes(int $idStation): array
    {
        return $this->db->fetchAll(
            'SELECT b.id_borne, b.num_borne, b.etat_borne,
                    v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie
               FROM borne b
               LEFT JOIN velo v ON v.id_borne = b.id_borne
              WHERE b.id_station = ?
              ORDER BY b.num_borne',
            [$idStation],
        );
    }

    /** Stations en service pour les listes déroulantes, avec leurs disponibilités. */
    public function options(): array
    {
        return $this->db->fetchAll(
            "SELECT id_station, nom, nb_velos_disponibles, nb_bornes_libres
               FROM v_stations_occupation
              WHERE etat_station = 'en_service'
              ORDER BY nom"
        );
    }

    /**
     * Toutes les stations (identifiant et nom) pour les listes de filtres.
     * Lecture directe de STATION (index uq_station_nom, déjà trié) : contrairement à
     * options(), n'agrège pas bornes et vélos de tout le réseau via la vue.
     */
    public function names(): array
    {
        return $this->db->fetchAll('SELECT id_station, nom FROM station ORDER BY nom');
    }

    /** Création d'une station et de ses bornes numérotées 1..n (transaction). */
    public function create(array $data, int $nbBornes): int
    {
        return $this->db->transaction(function (Database $db) use ($data, $nbBornes): int {
            $db->execute(
                'INSERT INTO station (nom, adresse, latitude, longitude, etat_station) VALUES (?, ?, ?, ?, ?)',
                [$data['nom'], $data['adresse'], $data['latitude'], $data['longitude'], $data['etat_station']],
            );
            $id = $db->lastInsertId();
            $this->insertBornes($db, $id, 1, $nbBornes);

            return $id;
        });
    }

    public function update(int $id, array $data): void
    {
        $this->db->execute(
            'UPDATE station SET nom = ?, adresse = ?, latitude = ?, longitude = ?, etat_station = ? WHERE id_station = ?',
            [$data['nom'], $data['adresse'], $data['latitude'], $data['longitude'], $data['etat_station'], $id],
        );
    }

    /** Ajoute $nb bornes à la suite des numéros existants. */
    public function addBornes(int $idStation, int $nb): void
    {
        $this->db->transaction(function (Database $db) use ($idStation, $nb): void {
            // Verrouille la station : deux ajouts simultanés ne peuvent pas prendre les mêmes numéros
            $db->fetchValue('SELECT id_station FROM station WHERE id_station = ? FOR UPDATE', [$idStation]);
            $next = (int) $db->fetchValue('SELECT COALESCE(MAX(num_borne), 0) + 1 FROM borne WHERE id_station = ?', [$idStation]);
            $this->insertBornes($db, $idStation, $next, $nb);
        });
    }

    public function setBorneEtat(int $idStation, int $idBorne, string $etat): bool
    {
        return $this->db->execute(
            'UPDATE borne SET etat_borne = ? WHERE id_borne = ? AND id_station = ?',
            [$etat, $idBorne, $idStation],
        ) > 0;
    }

    /**
     * Suppression d'une station et de ses bornes. Refusée par les clés étrangères
     * dès qu'une borne a un historique (locations, positions de vélos) : dans ce
     * cas on passe plutôt la station hors service.
     */
    public function delete(int $id): void
    {
        try {
            $this->db->transaction(function (Database $db) use ($id): void {
                $db->execute('DELETE FROM borne WHERE id_station = ?', [$id]);
                $db->execute('DELETE FROM station WHERE id_station = ?', [$id]);
            });
        } catch (BusinessException $e) {
            throw new BusinessException(
                'Cette station possède un historique (vélos, locations) : passez-la plutôt « hors service ».',
                0,
                $e,
            );
        }
    }

    private function insertBornes(Database $db, int $idStation, int $from, int $nb): void
    {
        if ($nb <= 0) {
            return;
        }
        $values = [];
        $params = [];
        for ($i = 0; $i < $nb; $i++) {
            $values[] = '(?, ?)';
            $params[] = $idStation;
            $params[] = $from + $i;
        }
        $db->execute('INSERT INTO borne (id_station, num_borne) VALUES ' . implode(', ', $values), $params);
    }
}
