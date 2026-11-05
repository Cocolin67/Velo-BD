<?php

declare(strict_types=1);

namespace App\Security;

use App\Support\Session;

/**
 * Utilisateur connecté, conservé en session.
 *
 * Rôles (tables héritées de UTILISATEUR) : usager, operateur, administrateur.
 * Un administrateur EST un opérateur : il dispose de tous les droits d'un opérateur.
 */
final class Auth
{
    public const USAGER    = 'usager';
    public const OPERATEUR = 'operateur';
    public const ADMIN     = 'administrateur';

    private const KEY = '_auth';

    public function __construct(
        private readonly Session $session,
        private readonly Csrf $csrf,
    ) {
    }

    /** @param array{id_utilisateur: int|string, nom: string, prenom: string, role: string, specialite?: ?string} $user */
    public function login(array $user, string $email): void
    {
        // Nouvel identifiant de session : empêche la fixation de session
        $this->session->regenerate();
        $this->csrf->rotate();
        $this->session->set(self::KEY, [
            'id'         => (int) $user['id_utilisateur'],
            'nom'        => $user['nom'],
            'prenom'     => $user['prenom'],
            'email'      => $email,
            'role'       => $user['role'],
            'specialite' => $user['specialite'] ?? null,
        ]);
    }

    public function logout(): void
    {
        // La session est conservée (pour le message flash) mais vidée de l'identité
        $this->session->remove(self::KEY);
        $this->session->regenerate();
        $this->csrf->rotate();
    }

    /** @return array{id: int, nom: string, prenom: string, email: string, role: string, specialite: ?string}|null */
    public function user(): ?array
    {
        return $this->session->get(self::KEY);
    }

    public function id(): ?int
    {
        return $this->user()['id'] ?? null;
    }

    public function check(): bool
    {
        return $this->user() !== null;
    }

    public function isUsager(): bool
    {
        return ($this->user()['role'] ?? null) === self::USAGER;
    }

    public function isStaff(): bool
    {
        return in_array($this->user()['role'] ?? null, [self::OPERATEUR, self::ADMIN], true);
    }

    public function isAdmin(): bool
    {
        return ($this->user()['role'] ?? null) === self::ADMIN;
    }

    /** @param list<string> $roles */
    public function hasAnyRole(array $roles): bool
    {
        $role = $this->user()['role'] ?? null;
        if ($role === null) {
            return false;
        }
        // L'administrateur hérite des droits de l'opérateur
        if ($role === self::ADMIN && in_array(self::OPERATEUR, $roles, true)) {
            return true;
        }

        return in_array($role, $roles, true);
    }

    /** Met à jour le nom affiché après une modification du profil. */
    public function refresh(string $nom, string $prenom, string $email): void
    {
        $user = $this->user();
        if ($user !== null) {
            $this->session->set(self::KEY, array_merge($user, ['nom' => $nom, 'prenom' => $prenom, 'email' => $email]));
        }
    }
}
