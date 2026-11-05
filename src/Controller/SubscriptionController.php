<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\SubscriptionRepository;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpForbiddenException;
use Slim\Views\Twig;

/** Abonnements de l'usager connecté. Les règles métier sont dans les procédures stockées. */
final class SubscriptionController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Auth $auth,
        private readonly SubscriptionRepository $subscriptions,
    ) {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $id = (int) $this->auth->id();

        return $this->render($response, 'subscriptions/index.twig', [
            'current'  => $this->subscriptions->current($id),
            'formules' => $this->subscriptions->formules(),
            'history'  => $this->subscriptions->history($id),
            'invoices' => $this->subscriptions->invoices($id),
        ]);
    }

    public function subscribe(Request $request, Response $response): Response
    {
        $data      = $this->form($request);
        $idFormule = self::int($data, 'id_formule');

        try {
            if ($idFormule === null) {
                throw new BusinessException('Choisissez une formule.');
            }
            $this->subscriptions->subscribe((int) $this->auth->id(), $idFormule, isset($data['renouvellement_auto']));
            $this->flash->success('Abonnement souscrit : vous pouvez emprunter un vélo.');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'subscriptions');
    }

    public function renew(Request $request, Response $response, array $args): Response
    {
        $id = $this->ownedOr403($request, (int) $args['id']);
        try {
            $this->subscriptions->renew($id);
            $this->flash->success('Abonnement renouvelé : la nouvelle période commence à la fin de l\'actuelle.');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'subscriptions');
    }

    public function cancel(Request $request, Response $response, array $args): Response
    {
        $id = $this->ownedOr403($request, (int) $args['id']);
        try {
            $this->subscriptions->cancel($id);
            $this->flash->success('Abonnement résilié.');
        } catch (BusinessException $e) {
            $this->flash->error($e->getMessage());
        }

        return $this->redirect($request, $response, 'subscriptions');
    }

    /** Un usager ne peut agir que sur ses propres abonnements. */
    private function ownedOr403(Request $request, int $id): int
    {
        if ($this->subscriptions->ownerOf($id) !== $this->auth->id()) {
            throw new HttpForbiddenException($request);
        }

        return $id;
    }
}
