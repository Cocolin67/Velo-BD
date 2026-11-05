<?php

declare(strict_types=1);

namespace App\Middleware;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Démarre une session PHP avec des cookies durcis et applique un délai d'inactivité.
 */
final class SessionMiddleware implements MiddlewareInterface
{
    /** @param array{name: string, lifetime: int, idle: int} $config */
    public function __construct(private readonly array $config)
    {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        if (session_status() !== PHP_SESSION_ACTIVE) {
            $https = $request->getUri()->getScheme() === 'https';

            ini_set('session.use_strict_mode', '1');      // refuse les identifiants inventés
            ini_set('session.use_only_cookies', '1');     // jamais d'identifiant dans l'URL
            session_name($this->config['name']);
            session_set_cookie_params([
                'lifetime' => $this->config['lifetime'],
                'path'     => '/',
                'secure'   => $https,
                'httponly' => true,                       // inaccessible au JavaScript
                'samesite' => 'Lax',                      // limite l'envoi depuis un autre site
            ]);
            session_start();
        }

        // Déconnexion automatique après une période d'inactivité
        $now = time();
        if (isset($_SESSION['_last_activity']) && $now - $_SESSION['_last_activity'] > $this->config['idle']) {
            $_SESSION = [];
            session_regenerate_id(true);
            $_SESSION['_flash'] = [['type' => 'info', 'message' => 'Session expirée, merci de vous reconnecter.']];
        }
        $_SESSION['_last_activity'] = $now;

        return $handler->handle($request);
    }
}
