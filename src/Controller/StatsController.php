<?php

declare(strict_types=1);

namespace App\Controller;

use App\Repository\StatsRepository;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpNotFoundException;
use Slim\Views\Twig;

final class StatsController extends Controller
{
    private const GRANULARITES = ['jour', 'semaine', 'mois'];

    public function __construct(Twig $view, Flash $flash, private readonly StatsRepository $stats)
    {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $p = $this->period($request->getQueryParams());

        $periods   = $this->stats->tripsByPeriod($p['debut'], $p['fin'], $p['granularite']);
        $hours     = $this->stats->peakHours($p['debut'], $p['fin']);
        $occupancy = $this->stats->occupancy($p['debut'], $p['fin']);

        $trips   = array_sum(array_column($periods, 'nb_trajets'));
        $minutes = array_sum(array_map(static fn ($r) => (float) $r['duree_moyenne_min'] * (int) $r['nb_trajets'], $periods));

        // Données des graphiques, encodées pour être insérées sans risque dans une balise <script>
        $charts = json_encode([
            'periods'   => ['labels' => array_column($periods, 'periode'), 'values' => array_map('intval', array_column($periods, 'nb_trajets'))],
            'hours'     => array_column($hours, 'nb_trajets'),
            'occupancy' => array_map(static fn (?float $v) => $v === null ? null : round($v * 100, 1), $occupancy['by_hour']),
        ], JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_THROW_ON_ERROR);

        $peak = $hours ? array_search(max(array_column($hours, 'nb_trajets')), array_column($hours, 'nb_trajets'), true) : null;

        return $this->render($response, 'stats/index.twig', [
            'period'     => $p,
            'kpi'        => [
                'trajets'   => $trips,
                'duree'     => $trips ? $minutes / $trips : null,
                'recettes'  => array_sum(array_column($periods, 'cout_total')),
                'pointe'    => $trips ? $peak : null,
            ],
            'routes'     => $this->stats->topRoutes($p['debut'], $p['fin']),
            'revenue'    => $this->stats->revenueByPlan($p['debut'], $p['fin']),
            'fleet'      => $this->stats->fleetUnavailability($p['debut'], $p['fin']),
            'busiest'    => array_slice($occupancy['by_station'], 0, 5),
            'emptiest'   => array_reverse(array_slice($occupancy['by_station'], -5)),
            'rebalance'  => $this->stats->stationsToRebalance(),
            'moves'      => $this->stats->proposedMoves(),
            'charts'     => $charts,
            'timings'    => $this->stats->timings(),
            'query'      => ['du' => $p['du'], 'au' => $p['au'], 'granularite' => $p['granularite']],
        ]);
    }

    /** Export CSV (séparateur « ; » et BOM UTF-8 pour Excel) d'un rapport sur la période. */
    public function export(Request $request, Response $response, array $args): Response
    {
        $p    = $this->period($request->getQueryParams());
        $rows = match ($args['rapport']) {
            'trajets'         => $this->stats->tripsByPeriod($p['debut'], $p['fin'], $p['granularite']),
            'heures'          => $this->hourRows($p),
            'origine-destination' => $this->stats->topRoutes($p['debut'], $p['fin'], 100),
            'recettes'        => $this->stats->revenueByPlan($p['debut'], $p['fin']),
            'remplissage'     => $this->stats->occupancy($p['debut'], $p['fin'])['rows'],
            'indisponibilite' => array_values($this->stats->fleetUnavailability($p['debut'], $p['fin'])),
            default           => throw new HttpNotFoundException($request),
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
