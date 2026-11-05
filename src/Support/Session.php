<?php

declare(strict_types=1);

namespace App\Support;

/**
 * Enveloppe minimale autour de $_SESSION (la session est démarrée par SessionMiddleware).
 */
final class Session
{
    public function get(string $key, mixed $default = null): mixed
    {
        return $_SESSION[$key] ?? $default;
    }

    public function set(string $key, mixed $value): void
    {
        $_SESSION[$key] = $value;
    }

    public function remove(string $key): void
    {
        unset($_SESSION[$key]);
    }

    /** Nouvel identifiant de session (à appeler à chaque changement de privilège). */
    public function regenerate(): void
    {
        if (session_status() === PHP_SESSION_ACTIVE) {
            session_regenerate_id(true);
        }
    }
}
