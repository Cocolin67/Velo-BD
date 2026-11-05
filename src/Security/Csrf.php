<?php

declare(strict_types=1);

namespace App\Security;

use App\Support\Session;

/**
 * Jeton anti-CSRF (Cross-Site Request Forgery) : un jeton aléatoire par session,
 * inclus dans chaque formulaire POST et vérifié par CsrfMiddleware.
 */
final class Csrf
{
    public const FIELD = '_csrf';
    private const KEY  = '_csrf_token';

    public function __construct(private readonly Session $session)
    {
    }

    public function token(): string
    {
        $token = $this->session->get(self::KEY);
        if (!is_string($token)) {
            $token = $this->rotate();
        }

        return $token;
    }

    public function rotate(): string
    {
        $token = bin2hex(random_bytes(32));
        $this->session->set(self::KEY, $token);

        return $token;
    }

    public function isValid(mixed $submitted): bool
    {
        $token = $this->session->get(self::KEY);

        return is_string($token) && is_string($submitted) && hash_equals($token, $submitted);
    }
}
