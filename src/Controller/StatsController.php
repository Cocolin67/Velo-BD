<?php

declare(strict_types=1);

namespace App\Controller;

use App\Repository\StatsRepository;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpNotFoundException;
use Slim\Views\Twig;

/**
 * Statistiques d'exploitation, réparties en onglets.
 *
 * Seules les procédures de l'onglet affiché sont exécutées (avant : les 8 procédures
 * sp_stat_* et de régulation à chaque affichage). Les indicateurs clés, communs à tous
 * les onglets, reposent sur deux procédures légères et mises en cache.
 * Les tableaux longs sont paginés.
 */
final class StatsController extends Controller
{
    private const GRANULARITES = ['jour', 'semaine', 'mois'];

    /** Onglets : clé => libellé */
    private const VUES = [
        'trajets'  => 'Trajets',
        'stations' => 'Stations et régulation',
        'recettes' => 'Recettes et flotte',
    ];

    /** Lignes par page des tableaux de la page */
    private const PER_TABLE = 10;

    /** Nombre maximal de trajets origine-destination consultables (paginés) */
    private const MAX_ROUTES = 100;

    public function __construct(Twig $view, Flash $flash, private readonly StatsRepository $stats)
    {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $query = $request->getQueryParams();
        $p     = $this->period($query);
        $vue   = self::oneOf($query, 'vue', array_keys(self::VUES), 'trajets');
        if (isset($query['rafraichir'])) {
            $this->stats->refresh();
        }

        // Indicateurs clés (tous les onglets)
        $periods = $this->stats->tripsByPeriod($p['debut'], $p['fin'], $p['granularite']);
        $hours   = $this->stats->peakHours($p['debut'], $p['fin']);
        $trips   = array_sum(array_column($periods, 'nb_trajets'));
        $minutes = array_sum(array_map(static fn ($r) => (float) $r['duree_moyenne_min'] * (int) $r['nb_trajets'], $periods));
        $counts  = array_column($hours, 'nb_trajets');

        $base  = ['du' => $p['du'], 'au' => $p['au'], 'granularite' => $p['granularite']];
        $pages = [];   // page courante des autres tableaux, conservée quand on en pagine un
        foreach (['p_od', 'p_st', 'p_reg', 'p_dep'] as $key) {
            if (self::pageOf($query, $key) > 1) {
                $pages[$key] = self::pageOf($query, $key);
            }
        }
        $data = [
            'period' => $p,
            'vue'    => $vue,
            'vues'   => self::VUES,
            'kpi'    => [
                'trajets'  => $trips,
                'duree'    => $trips ? $minutes / $trips : null,
                'recettes' => array_sum(array_column($periods, 'cout_total')),
                'pointe'   => $trips ? array_search(max($counts), $counts, true) : null,
            ],
            'query'  => $base,                    // liens d'export CSV
            'page_q' => $base + ['vue' => $vue] + $pages,  // liens de pagination
        ];
        $charts = [];

        switch ($vue) {
            case 'trajets':
                $charts = [
                    'periods' => ['labels' => array_column($periods, 'periode'), 'values' => array_map('intval', array_column($periods, 'nb_trajets'))],
                    'hours'   => $counts,
                ];
                $data['routes'] = self::paginate(
                    $this->stats->topRoutes($p['debut'], $p['fin'], self::MAX_ROUTES),
                    self::pageOf($query, 'p_od'),
                );
                break;

            case 'stations':
                $occupancy          = $this->stats->occupancy($p['debut'], $p['fin']);
                $charts             = ['occupancy' => array_map(static fn (?float $v) => $v === null ? null : round($v * 100, 1), $occupancy['by_hour'])];
                $data['occupancy']  = self::paginate($occupancy['by_station'], self::pageOf($query, 'p_st'));
                $data['rebalance']  = self::paginate($this->stats->stationsToRebalance(), self::pageOf($query, 'p_reg'));
                $data['moves']      = self::paginate($this->stats->proposedMoves(), self::pageOf($query, 'p_dep'));
                break;

            case 'recettes':
                $data['revenue'] = $this->stats->revenueByPlan($p['debut'], $p['fin']);
                $data['fleet']   = $this->stats->fleetUnavailability($p['debut'], $p['fin']);
                break;
        }

        // Données des graphiques, encodées pour être insérées sans risque dans une balise <script>
        $data['charts']  = json_encode($charts, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_THROW_ON_ERROR);
        $data['timings'] = $this->stats->timings();

        return $this->render($response, 'stats/index.twig', $data);
    }

    /** Export CSV (séparateur « ; » et BOM UTF-8 pour Excel) d'un rapport sur la période. */
    public function export(Request $request, Response $response, array $args): Response
    {
        $p    = $this->period($request->getQueryParams());
        $rows = match ($args['rapport']) {
            'trajets'             => $this->stats->tripsByPeriod($p['debut'], $p['fin'], $p['granularite']),
            'heures'              => $this->hourRows($p),
            'origine-destination' => $this->stats->topRoutes($p['debut'], $p['fin'], self::MAX_ROUTES),
            'recettes'            => $this->stats->revenueByPlan($p['debut'], $p['fin']),
            'remplissage'         => $this->stats->occupancy($p['debut'], $p['fin'])['rows'],
            'indisponibilite'     => array_values($this->stats->fleetUnavailability($p['debut'], $p['fin'])),
            default               => throw new HttpNotFoundException($request),
        };

        $out = fopen('php://temp', 'r+');
        fwrite($out, "\xEF\xBB\xBF");
        if ($rows) {
            fputcsv($out, array_keys($rows[0]), ';', '"', '');
            foreach ($rows as $row) {
                // Décimales à la française (virgule) pour une ouverture directe dans Excel
                fputcsv($out, array_map(
                    static fn ($v) => is_float($v) || (is_string($v) && is_numeric($v)) ? str_replace('.', ',', (string) $v) : $v,
                    $row,
                ), ';', '"', '');
            }
        }
        rewind($out);
        $response->getBody()->write((string) stream_get_contents($out));
        fclose($out);

        $filename = sprintf('%s_%s_%s.csv', $args['rapport'], $p['du'], $p['au']);

        return $response
            ->withHeader('Content-Type', 'text/csv; charset=utf-8')
            ->withHeader('Content-Disposition', 'attachment; filename="' . $filename . '"');
    }

    /**
     * Découpe un résultat déjà calculé (et mis en cache) en pages.
     *
     * @return array{rows: list<array<string, mixed>>, page: int, has_next: bool, total: int, from: int, to: int}
     */
    private static function paginate(array $rows, int $page): array
    {
        $total = count($rows);
        $last  = max(1, (int) ceil($total / self::PER_TABLE));
        $page  = min($page, $last);
        $slice = array_slice($rows, ($page - 1) * self::PER_TABLE, self::PER_TABLE);

        return [
            'rows'     => $slice,
            'page'     => $page,
            'has_next' => $page < $last,
            'total'    => $total,
            'from'     => $slice ? ($page - 1) * self::PER_TABLE + 1 : 0,
            'to'       => ($page - 1) * self::PER_TABLE + count($slice),
        ];
    }

    private static function pageOf(array $query, string $key): int
    {
        return max(1, min(1000, self::int($query, $key) ?? 1));
    }

    /** Heures de pointe sous forme de lignes (heure, nb_trajets, rang) pour l'export. */
    private function hourRows(array $p): array
    {
        $rows = [];
        foreach ($this->stats->peakHours($p['debut'], $p['fin']) as $hour => $r) {
            $rows[] = ['heure' => $hour, 'nb_trajets' => $r['nb_trajets'], 'rang' => $r['rang']];
        }

        return $rows;
    }

    /** Période demandée (30 derniers jours par défaut) ; « au » est inclus, d'où fin = au + 1 jour. */
    private function period(array $query): array
    {
        $au = self::date($query, 'au') ?? date('Y-m-d');
        $du = self::date($query, 'du') ?? date('Y-m-d', strtotime($au . ' -29 days'));
        if ($du > $au) {
            [$du, $au] = [$au, $du];
        }

        return [
            'du'          => $du,
            'au'          => $au,
            'debut'       => $du . ' 00:00:00',
            'fin'         => date('Y-m-d', strtotime($au . ' +1 day')) . ' 00:00:00',
            'granularite' => self::oneOf($query, 'granularite', self::GRANULARITES, 'jour'),
        ];
    }
}
