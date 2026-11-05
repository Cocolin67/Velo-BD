<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;
use App\Support\Cache;

/**
 * Statistiques d'exploitation : enveloppe des procédures sp_stat_* et de régulation.
 *
 * Optimisations côté application :
 *   - chaque résultat est mis en cache (fichier) : une période entièrement passée est
 *     gardée 1 h, une période qui inclut aujourd'hui 5 min, l'occupation en temps réel 30 s ;
 *   - refresh(true) force le recalcul (bouton « Recalculer » de la page) ;
 *   - chaque appel est chronométré, en indiquant s'il a été servi par le cache
 *     (affiché sur la page, utile au rapport de performances).
 *
 * Période : $debut inclus, $fin exclu (convention des procédures).
 */
final class StatsRepository
{
    /** @var array<string, array{ms: float, cache: bool}> durée de chaque appel, en millisecondes */
    private array $timings = [];

    private bool $refresh = false;

    /** @param array{historique: int, recent: int, temps_reel: int} $ttl */
    public function __construct(
        private readonly Database $db,
        private readonly Cache $cache,
        private readonly array $ttl = ['historique' => 3600, 'recent' => 300, 'temps_reel' => 30],
    ) {
    }

    /** Ignore le cache pour les appels suivants (les résultats recalculés y sont réécrits). */
    public function refresh(bool $refresh = true): void
    {
        $this->refresh = $refresh;
    }

    public function tripsByPeriod(string $debut, string $fin, string $granularite): array
    {
        return $this->timed('sp_stat_trajets_par_periode', [$debut, $fin, $granularite], $this->periodTtl($fin));
    }

    /** Trajets par heure de départ, complétés à 0 pour les 24 heures. */
    public function peakHours(string $debut, string $fin): array
    {
        $rows  = $this->timed('sp_stat_heures_pointe', [$debut, $fin], $this->periodTtl($fin));
        $hours = array_fill(0, 24, ['nb_trajets' => 0, 'rang' => null]);
        foreach ($rows as $r) {
            $hours[(int) $r['heure']] = ['nb_trajets' => (int) $r['nb_trajets'], 'rang' => (int) $r['rang']];
        }

        return $hours;
    }

    public function topRoutes(string $debut, string $fin, int $limit = 10): array
    {
        return $this->timed('sp_stat_trajets_od', [$debut, $fin, $limit], $this->periodTtl($fin));
    }

    public function revenueByPlan(string $debut, string $fin): array
    {
        return $this->timed('sp_stat_recettes_par_formule', [$debut, $fin], $this->periodTtl($fin));
    }

    /** @return array<string, array<string, mixed>> indexé par type : mecanique, electrique, tous */
    public function fleetUnavailability(string $debut, string $fin): array
    {
        $out = [];
        foreach ($this->timed('sp_stat_indisponibilite_flotte', [$debut, $fin], $this->periodTtl($fin)) as $r) {
            $out[$r['type_velo']] = $r;
        }

        return $out;
    }

    /**
     * Taux de remplissage d'après les relevés (RELEVE_STATION) :
     * moyenne par heure sur toutes les stations, et moyenne par station.
     *
     * @return array{by_hour: list<?float>, by_station: list<array{id_station: int, nom: string, taux: float}>, rows: list<array<string, mixed>>}
     */
    public function occupancy(string $debut, string $fin): array
    {
        $rows      = $this->timed('sp_stat_remplissage_stations', [$debut, $fin], $this->periodTtl($fin));
        $hours     = array_fill(0, 24, []);
        $byStation = [];
        foreach ($rows as $r) {
            if ($r['taux_remplissage_moyen'] === null) {
                continue;
            }
            $id                         = (int) $r['id_station'];
            $hours[(int) $r['heure']][] = (float) $r['taux_remplissage_moyen'];
            $byStation[$id]['nom']      = $r['nom'];
            $byStation[$id]['t'][]      = (float) $r['taux_remplissage_moyen'];
        }

        $stations = [];
        foreach ($byStation as $id => $s) {
            $stations[] = ['id_station' => $id, 'nom' => $s['nom'], 'taux' => array_sum($s['t']) / count($s['t'])];
        }
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
        return $this->timed('sp_stations_a_reequilibrer', [$low, $high], $this->ttl['temps_reel']);
    }

    /** Déplacements proposés : station pleine → station vide la plus proche. */
    public function proposedMoves(float $low = 0.2, float $high = 0.8): array
    {
        return $this->timed('sp_proposer_deplacements', [$low, $high], $this->ttl['temps_reel']);
    }

    /**
     * Indicateurs du jour pour le tableau de bord de l'exploitant. Non mis en cache :
     * chaque sous-requête est servie par un index (velo_en_cours, idx_loc_emprunt couvrant,
     * idx_sig_statut_date) et ne lit que les lignes du jour.
     */
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

    /** @return array<string, array{ms: float, cache: bool}> */
    public function timings(): array
    {
        return $this->timings;
    }

    /** Durée de cache d'une statistique sur période : longue si la période est close. */
    private function periodTtl(string $fin): int
    {
        return strtotime($fin) <= strtotime('today') ? $this->ttl['historique'] : $this->ttl['recent'];
    }

    private function timed(string $procedure, array $params, int $ttl): array
    {
        $start = hrtime(true);
        $rows  = $this->cache->remember(
            'stats:' . $procedure . ':' . json_encode($params),
            $ttl,
            fn (): array => $this->db->call($procedure, $params)['rows'][0] ?? [],
            $hit,
            $this->refresh,
        );
        $this->timings[$procedure] = ['ms' => (hrtime(true) - $start) / 1e6, 'cache' => (bool) $hit];

        return $rows;
    }
}
