<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\StationRepository;
use App\Support\Flash;
use App\Support\Sort;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpNotFoundException;
use Slim\Views\Twig;

final class StationController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly StationRepository $stations,
    ) {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $query   = $request->getQueryParams();
        $filters = [
            'q'     => self::str($query, 'q', 100),
            'etat'  => self::oneOf($query, 'etat', StationRepository::ETATS),
            'dispo' => self::oneOf($query, 'dispo', ['velos', 'electriques', 'bornes']),
        ];
        $tri    = Sort::fromQuery($query, array_keys(StationRepository::SORTABLE));
        $page   = self::page($query);
        $result = $this->stations->search($filters, $page, self::PER_PAGE, $tri);

        return $this->render($response, 'stations/index.twig', [
            'stations' => $result['rows'],
            'has_next' => $result['has_next'],
            'page'     => $page,
            'filters'  => $filters,
            'query'    => array_filter($filters) + $tri->params(),
            'tri'      => $tri->view('stations', array_filter($filters)),
            'etats'    => StationRepository::ETATS,
        ]);
    }

    public function show(Request $request, Response $response, array $args): Response
    {
        $station = $this->findOr404($request, (int) $args['id']);

        return $this->render($response, 'stations/show.twig', [
            'station' => $station,
            'bornes'  => $this->stations->bornes((int) $station['id_station']),
        ]);
    }

    public function createForm(Request $request, Response $response): Response
    {
        return $this->render($response, 'stations/form.twig', [
            'station' => ['etat_station' => 'en_service', 'nb_bornes' => 10],
            'etats'   => StationRepository::ETATS,
        ]);
    }

    public function create(Request $request, Response $response): Response
    {
        [$data, $errors] = $this->validate($this->form($request), true);

        if (!$errors) {
            try {
                $id = $this->stations->create($data, $data['nb_bornes']);
                $this->flash->success(sprintf('Station « %s » créée avec %d bornes.', $data['nom'], $data['nb_bornes']));

                return $this->redirect($request, $response, 'stations.show', ['id' => $id]);
            } catch (BusinessException $e) {
                $errors['nom'] = $e->getMessage();
            }
        }

        return $this->render($response->withStatus(422), 'stations/form.twig', [
            'station' => $data, 'errors' => $errors, 'etats' => StationRepository::ETATS,
        ]);
    }

    public function editForm(Request $request, Response $response, array $args): Response
    {
        return $this->render($response, 'stations/form.twig', [
            'station' => $this->findOr404($request, (int) $args['id']),
            'etats'   => StationRepository::ETATS,
        ]);
    }

    public function update(Request $request, Response $response, array $args): Response
    {
        $station         = $this->findOr404($request, (int) $args['id']);
        [$data, $errors] = $this->validate($this->form($request), false);

        if (!$errors) {
            try {
                $this->stations->update((int) $station['id_station'], $data);
                if ($data['nb_bornes_ajout'] > 0) {
                    $this->stations->addBornes((int) $station['id_station'], $data['nb_bornes_ajout']);
                }
                $this->flash->success('Station mise à jour.');

                return $this->redirect($request, $response, 'stations.show', ['id' => $station['id_station']]);
            } catch (BusinessException $e) {
                $errors['nom'] = $e->getMessage();
            }
        }

        return $this->render($response->withStatus(422), 'stations/form.twig', [
            'station' => array_merge($station, $data), 'errors' => $errors, 'etats' => StationRepository::ETATS,
        ]);
    }

    public function delete(Request $request, Response $response, array $args): Response
    {
        $station = $this->findOr404($request, (int) $args['id']);
        try {
            $this->stations->delete((int) $station['id_station']);
            $this->flash->success(sprintf('Station « %s » supprimée.', $station['nom']));

            return $this->redirect($request, $response, 'stations');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());

            return $this->redirect($request, $response, 'stations.show', ['id' => $station['id_station']]);
        }
    }

    public function borneEtat(Request $request, Response $response, array $args): Response
    {
        $etat = self::oneOf($this->form($request), 'etat_borne', StationRepository::ETATS_BORNE);
        if ($etat !== null && $this->stations->setBorneEtat((int) $args['id'], (int) $args['borne'], $etat)) {
            $this->flash->success('État de la borne modifié.');
        }

        return $this->redirect($request, $response, 'stations.show', ['id' => (int) $args['id']]);
    }

    private function findOr404(Request $request, int $id): array
    {
        return $this->stations->find($id) ?? throw new HttpNotFoundException($request, 'Station introuvable');
    }

    /** @return array{0: array<string, mixed>, 1: array<string, string>} */
    private function validate(array $form, bool $creating): array
    {
        $data = [
            'nom'          => self::str($form, 'nom', 150),
            'adresse'      => self::str($form, 'adresse', 255),
            'latitude'     => self::str($form, 'latitude', 20),
            'longitude'    => self::str($form, 'longitude', 20),
            'etat_station' => self::oneOf($form, 'etat_station', StationRepository::ETATS, 'en_service'),
        ];
        $errors = [];

        if ($data['nom'] === '') {
            $errors['nom'] = 'Le nom est obligatoire.';
        }
        if ($data['adresse'] === '') {
            $errors['adresse'] = 'L\'adresse est obligatoire.';
        }
        foreach (['latitude' => 90, 'longitude' => 180] as $key => $max) {
            $value = str_replace(',', '.', $data[$key]);
            if (!is_numeric($value) || abs((float) $value) > $max) {
                $errors[$key] = sprintf('Valeur entre -%d et %d attendue.', $max, $max);
            } else {
                $data[$key] = round((float) $value, 6);
            }
        }

        $key   = $creating ? 'nb_bornes' : 'nb_bornes_ajout';
        $count = self::int($form, $key) ?? ($creating ? null : 0);
        if ($count === null || $count > 100 || ($creating && $count < 1)) {
            $errors[$key] = $creating ? 'Entre 1 et 100 bornes.' : 'Entre 0 et 100 bornes.';
        }
        $data[$key] = $count ?? 0;

        return [$data, $errors];
    }
}
