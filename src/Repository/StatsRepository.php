<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;

/**
 * Statistiques d'exploitation : enveloppe des procédures sp_stat_* et de régulation.
 * Chaque appel est chronométré (affiché sur la page, utile au rapport de performances).
 *
 * Période : $debut inclus, $fin exclu (convention des procédures).
 */
final class StatsRepository
{
    /** @var array<string, float> durée de chaque requête, en millisecondes */
    private array $timings = [];

    public function __construct(private readonly Database $db)
    {
    }

    public function tripsByPeriod(string $debut, string $fin, string $granularite): array
    {
        return $this->timed('sp_stat_trajets_par_periode', [$debut, $fin, $granularite]);
    }

    /** Trajets par heure de départ, complétés à 0 pour les 24 heures. */
    public function peakHours(string $debut, string $fin): array
    {
        $rows  = $this->timed('sp_stat_heures_pointe', [$debut, $fin]);
        $hours = array_fill(0, 24, ['nb_trajets' => 0, 'rang' => null]);
        foreach ($rows as $r) {
            $hours[(int) $r['heure']] = ['nb_trajets' => (int) $r['nb_trajets'], 'rang' => (int) $r['rang']];
        }

        return $hours;
    }

    public function topRoutes(string $debut, string $fin, int $limit = 10): array
    {
        return $this->timed('sp_stat_trajets_od', [$debut, $fin, $limit]);
    }

    public function revenueByPlan(string $debut, string $fin): array
    {
        return $this->timed('sp_stat_recettes_par_formule', [$debut, $fin]);
    }

    /** @return array<string, array<string, mixed>> indexé par type : mecanique, electrique, tous */
    public function fleetUnavailability(string $debut, string $fin): array
    {
        $out = [];
        foreach ($this->timed('sp_stat_indisponibilite_flotte', [$debut, $fin]) as $r) {
            $out[$r['type_velo']] = $r;
        }

        return $out;
    }

    /**
     * Taux de remplissage d'après les relevés (RELEVE_STATION) :
     * moyenne par heure sur toutes les stations, et moyenne par station.
     *
     * @return array{by_hour: list<?float>, by_station: list<array{nom: string, taux: float}>, rows: list<array<string, mixed>>}
     */
    public function occupancy(string $debut, string $fin): array
    {
        $rows      = $this->timed('sp_stat_remplissage_stations', [$debut, $fin]);
        $hours     = array_fill(0, 24, []);
        $byStation = [];
        foreach ($rows as $r) {
            if ($r['taux_remplissage_moyen'] === null) {
                continue;
            }
            $hours[(int) $r['heure']][]       = (float) $r['taux_remplissage_moyen'];
            $byStation[$r['id_station']]['nom'] = $r['nom'];
            $byStation[$r['id_station']]['t'][] = (float) $r['taux_remplissage_moyen'];
        }

        $stations = array_map(
            static fn (array $s): array => ['nom' => $s['nom'], 'taux' => array_sum($s['t']) / count($s['t'])],
            array_values($byStation),
        );
        usort($stations, static fn (array $a, array $b): int => $b['taux'] <=> $a['taux']);

        return [
            'by_hour'    => array_map(static fn (array $v): ?float => $v ? array_sum($v) / count($v) : null, $hours),
            'by_station' => $stations,
            'rows'       => $rows,
        ];
    }

    /** Stations vides (≤ seuil bas) ou pleines (≥ seuil haut), en temps réel. */
    public function stationsToRebalance(float $low = 0.2, float $high = 0.8): array
    {
        return $this->timed('sp_stations_a_reequilibrer', [$low, $high]);
    }

    /** Déplacements proposés : station pleine → station vide la plus proche. */
    public function proposedMoves(float $low = 0.2, float $high = 0.8): array
    {
        return $this->timed('sp_proposer_deplacements', [$low, $high]);
    }

    /** Indicateurs du jour pour le tableau de bord de l'exploitant (requêtes servies par index). */
    public function today(): array
    {
        return $this->db->fetchOne(
            "SELECT (SELECT COUNT(*) FROM location WHERE velo_en_cours IS NOT NULL)          AS en_cours,
                    (SELECT COUNT(*) FROM location WHERE date_heure_emprunt >= CURDATE())    AS trajets_jour,
                    (SELECT COALESCE(SUM(cout), 0) FROM location
                      WHERE date_heure_emprunt >= CURDATE())                                 AS recettes_jour,
                    (SELECT COUNT(*) FROM signalement WHERE statut = 'ouvert')               AS signalements"
        ) ?? [];
    }

    /** @return array<string, float> */
    public function timings(): array
    {
        return $this->timings;
    }

    private function timed(string $procedure, array $params): array
    {
        $start = hrtime(true);
        $rows  = $this->db->call($procedure, $params)['rows'][0] ?? [];
        $this->timings[$procedure] = (hrtime(true) - $start) / 1e6;

        return $rows;
    }
}
