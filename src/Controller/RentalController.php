<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\RentalRepository;
use App\Repository\StationRepository;
use App\Repository\SubscriptionRepository;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

final class RentalController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Auth $auth,
        private readonly RentalRepository $rentals,
        private readonly StationRepository $stations,
        private readonly SubscriptionRepository $subscriptions,
    ) {
        parent::__construct($view, $flash);
    }

    /** Usager : location en cours, emprunt / restitution, historique. */
    public function index(Request $request, Response $response): Response
    {
        $id        = (int) $this->auth->id();
        $query     = $request->getQueryParams();
        $page      = self::page($query);
        $idStation = self::int($query, 'station');
        $current   = $this->rentals->current($id);
        $history   = $this->rentals->history($id, $page, self::PER_PAGE);

        return $this->render($response, 'rentals/index.twig', [
            'current'      => $current,
            'subscription' => $current ? null : $this->subscriptions->current($id),
            'stations'     => $this->stations->options(),
            'station_id'   => $idStation,
            'bikes'        => !$current && $idStation ? $this->rentals->availableBikes($idStation) : [],
            'summary'      => $this->rentals->summary($id),
            'history'      => $history['rows'],
            'has_next'     => $history['has_next'],
            'page'         => $page,
        ]);
    }

    public function borrow(Request $request, Response $response): Response
    {
        $idVelo = self::int($this->form($request), 'id_velo');
        try {
            if ($idVelo === null) {
                throw new BusinessException('Vélo non précisé.');
            }
            $this->rentals->borrow((int) $this->auth->id(), $idVelo);
            $this->flash->success(sprintf('Vélo #%d emprunté. Bonne route !', $idVelo));
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'rentals');
    }

    public function giveBack(Request $request, Response $response): Response
    {
        $idStation = self::int($this->form($request), 'id_station');
        try {
            $idBorne = $idStation ? $this->rentals->freeDock($idStation) : null;
            if ($idBorne === null) {
                throw new BusinessException('Aucune borne libre dans cette station : choisissez-en une autre.');
            }
            $result = $this->rentals->giveBack((int) $this->auth->id(), $idBorne);
            $this->flash->success(sprintf(
                'Vélo rendu. Trajet de %d min, coût : %s €.',
                $result['duree_min'],
                number_format((float) $result['cout'], 2, ',', ' '),
            ));
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'rentals');
    }

    /** Opérateurs : toutes les locations, filtrées. */
    public function admin(Request $request, Response $response): Response
    {
        $query   = $request->getQueryParams();
        $filters = [
            'statut'  => self::oneOf($query, 'statut', ['en_cours', 'terminees']),
            'du'      => self::date($query, 'du') ?? date('Y-m-d', strtotime('-7 days')),
            'au'      => self::date($query, 'au') ?? date('Y-m-d'),
            'station' => self::int($query, 'station'),
            'type'    => self::oneOf($query, 'type', ['mecanique', 'electrique']),
            'q'       => self::str($query, 'q', 100),
        ];
        $page   = self::page($query);
        $result = $this->rentals->search($filters, $page, self::PER_PAGE);

        return $this->render($response, 'rentals/admin.twig', [
            'rentals'  => $result['rows'],
            'has_next' => $result['has_next'],
            'page'     => $page,
            'filters'  => $filters,
            'query'    => array_filter($filters, static fn ($v) => $v !== null && $v !== ''),
            'stations' => $this->stations->options(),
        ]);
    }
}
