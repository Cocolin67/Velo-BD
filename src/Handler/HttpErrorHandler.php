<?php

declare(strict_types=1);

namespace App\Handler;

use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Slim\Exception\HttpException;
use Slim\Views\Twig;

/**
 * Affiche une page d'erreur propre (404, 403, 500...). Le détail technique n'est
 * montré qu'en mode debug ; en production il est seulement journalisé.
 */
final class HttpErrorHandler
{
    public function __construct(
        private readonly Twig $view,
        private readonly ResponseFactoryInterface $responses,
    ) {
    }

    public function __invoke(
        ServerRequestInterface $request,
        \Throwable $exception,
        bool $displayErrorDetails,
        bool $logErrors,
        bool $logErrorDetails,
    ): ResponseInterface {
        $status = $exception instanceof HttpException ? $exception->getCode() : 500;

        if ($status >= 500 && $logErrors) {
            error_log(sprintf('[velo] %s: %s in %s:%d', $exception::class, $exception->getMessage(), $exception->getFile(), $exception->getLine()));
        }

        $titles = [
            403 => 'Accès refusé',
            404 => 'Page introuvable',
            405 => 'Méthode non autorisée',
        ];

        $response = $this->responses->createResponse($status);
        try {
            return $this->view->render($response, 'error.twig', [
                'status'  => $status,
                'title'   => $titles[$status] ?? 'Erreur interne',
                'message' => $exception instanceof HttpException ? $exception->getDescription() : null,
                'details' => $displayErrorDetails ? (string) $exception : null,
            ]);
        } catch (\Throwable) {
            // Dernier recours si le rendu Twig échoue lui-même
            $response->getBody()->write('<h1>' . $status . '</h1>');

            return $response;
        }
    }
}
