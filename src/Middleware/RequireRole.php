<?php

declare(strict_types=1);

namespace App\Middleware;

use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;
use Slim\Exception\HttpForbiddenException;
use Slim\Routing\RouteContext;

/**
 * Contrôle d'accès d'un groupe de routes :
 *   - visiteur non connecté → redirection vers la page de connexion ;
 *   - rôle insuffisant      → 403.
 * Une liste de rôles vide signifie « tout utilisateur connecté ».
 */
final class RequireRole implements MiddlewareInterface
{
    /** @param list<string> $roles */
    public function __construct(
        private readonly Auth $auth,
        private readonly Flash $flash,
        private readonly ResponseFactoryInterface $responses,
        private readonly array $roles = [],
    ) {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        if (!$this->auth->check()) {
            $this->flash->info('Connectez-vous pour accéder à cette page.');
            $url = RouteContext::fromRequest($request)->getRouteParser()->urlFor('login');

            return $this->responses->createResponse(303)->withHeader('Location', $url);
        }

        if ($this->roles && !$this->auth->hasAnyRole($this->roles)) {
            $e = new HttpForbiddenException($request);
            $e->setDescription('Votre compte n\'a pas les droits nécessaires pour cette page.');
            throw $e;
        }

        return $handler->handle($request);
    }
}
