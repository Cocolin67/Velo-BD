<?php

declare(strict_types=1);

namespace App\Controller;

use App\Repository\BikeRepository;
use App\Repository\StationRepository;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpNotFoundException;
use Slim\Views\Twig;

/** Flotte (opérateurs) : recherche multicritère et fiche détaillée d'un vélo. */
final class BikeController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly BikeRepository $bikes,
        private readonly StationRepository $stations,
    ) {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $query    = $request->getQueryParams();
        $batterie = self::int($query, 'batterie');
        $filters  = [
            'id'       => self::int($query, 'id'),
            'type'     => self::oneOf($query, 'type', BikeRepository::TYPES),
            'etat'     => self::oneOf($query, 'etat', BikeRepository::ETATS),
            'station'  => self::int($query, 'station'),
            'batterie' => $batterie !== null ? min($batterie, 100) : null,
        ];
        $page   = self::page($query);
        $result = $this->bikes->search($filters, $page, self::PER_PAGE);

        return $this->render($response, 'bikes/index.twig', [
            'bikes'    => $result['rows'],
            'has_next' => $result['has_next'],
            'page'     => $page,
            'filters'  => $filters,
            'query'    => array_filter($filters, static fn ($v) => $v !== null),
            'counts'   => $this->bikes->countByState(),
            'stations' => $this->stations->options(),
            'etats'    => BikeRepository::ETATS,
        ]);
    }

    public function show(Request $request, Response $response, array $args): Response
    {
        $id   = (int) $args['id'];
        $bike = $this->bikes->find($id) ?? throw new HttpNotFoundException($request, 'Vélo introuvable');

        return $this->render($response, 'bikes/show.twig', [
            'bike'          => $bike,
            'states'        => $this->bikes->stateHistory($id),
            'positions'     => $this->bikes->positionHistory($id),
            'rentals'       => $this->bikes->rentals($id),
            'interventions' => $this->bikes->interventions($id),
            'reports'       => $this->bikes->reports($id),
        ]);
    }
}
