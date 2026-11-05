<?php

declare(strict_types=1);

namespace App\Middleware;

use App\Security\Csrf;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;
use Slim\Exception\HttpForbiddenException;

/** Refuse toute requête modifiant des données sans jeton CSRF valide. */
final class CsrfMiddleware implements MiddlewareInterface
{
    public function __construct(private readonly Csrf $csrf)
    {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        if (!in_array($request->getMethod(), ['GET', 'HEAD', 'OPTIONS'], true)) {
            $body = (array) ($request->getParsedBody() ?? []);
            if (!$this->csrf->isValid($body[Csrf::FIELD] ?? null)) {
                $e = new HttpForbiddenException($request, 'Jeton CSRF invalide');
                $e->setDescription('Le formulaire a expiré ou ne provient pas de ce site. Rechargez la page puis réessayez.');
                throw $e;
            }
        }

        return $handler->handle($request);
    }
}
