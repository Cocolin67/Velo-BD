<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\ReportRepository;
use App\Repository\StationRepository;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

final class ReportController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Auth $auth,
        private readonly ReportRepository $reports,
        private readonly StationRepository $stations,
    ) {
        parent::__construct($view, $flash);
    }

    /** Formulaire + mes signalements (usager) ou file de traitement (opérateurs). */
    public function index(Request $request, Response $response): Response
    {
        $query = $request->getQueryParams();
        $data  = [
            'stations' => $this->stations->options(),
            'old'      => ['id_velo' => self::int($query, 'velo'), 'id_station' => self::int($query, 'station')],
        ];

        if ($this->auth->isStaff()) {
            $filters = [
                'statut' => self::oneOf($query, 'statut', ReportRepository::STATUTS),
                'cible'  => self::oneOf($query, 'cible', ['velo', 'station']),
            ];
            $page   = self::page($query);
            $result = $this->reports->search($filters, $page, self::PER_PAGE);
            $data  += [
                'reports'  => $result['rows'],
                'has_next' => $result['has_next'],
                'page'     => $page,
                'filters'  => $filters,
                'query'    => array_filter($filters),
                'counts'   => $this->reports->countByStatus(),
            ];
        } else {
            $data['reports'] = $this->reports->byAuthor((int) $this->auth->id());
        }

        return $this->render($response, 'reports/index.twig', $data);
    }

    public function create(Request $request, Response $response): Response
    {
        $form        = $this->form($request);
        $idVelo      = self::int($form, 'id_velo');
        $idStation   = self::int($form, 'id_station');
        $description = self::str($form, 'description', 1000);

        try {
            if (($idVelo === null) === ($idStation === null)) {
                throw new BusinessException('Indiquez soit un numéro de vélo, soit une station (pas les deux).');
            }
            if (mb_strlen($description) < 5) {
                throw new BusinessException('Décrivez le problème en quelques mots.');
            }
            $this->reports->create((int) $this->auth->id(), $idVelo, $idStation, $description);
            $this->flash->success($idVelo
                ? sprintf('Merci ! Le vélo #%d est signalé et ne peut plus être emprunté jusqu\'à son contrôle.', $idVelo)
                : 'Merci ! Votre signalement a été transmis à l\'équipe de maintenance.');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'reports');
    }

    public function takeCharge(Request $request, Response $response, array $args): Response
    {
        $this->reports->takeCharge((int) $args['id'])
            ? $this->flash->success('Signalement pris en charge.')
            : $this->flash->error('Ce signalement n\'est plus ouvert.');

        return $this->redirect($request, $response, 'reports', [], ['statut' => 'pris_en_charge']);
    }

    public function close(Request $request, Response $response, array $args): Response
    {
        try {
            $this->reports->close((int) $args['id']);
            $this->flash->success('Signalement clos. Le vélo est remis en service s\'il n\'est plus bloqué.');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'reports');
    }
}
