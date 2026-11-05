<?php

declare(strict_types=1);

namespace App\Twig;

use App\Security\Auth;
use App\Security\Csrf;
use Twig\Extension\AbstractExtension;
use Twig\TwigFunction;

/** Accès à l'utilisateur connecté et au jeton CSRF depuis les templates. */
final class SecurityExtension extends AbstractExtension
{
    public function __construct(
        private readonly Auth $auth,
        private readonly Csrf $csrf,
    ) {
    }

    public function getFunctions(): array
    {
        return [
            new TwigFunction('current_user', fn (): ?array => $this->auth->user()),
            new TwigFunction('is_granted', fn (string ...$roles): bool => $this->auth->hasAnyRole($roles)),
            new TwigFunction('csrf_field', fn (): string => sprintf(
                '<input type="hidden" name="%s" value="%s">',
                Csrf::FIELD,
                htmlspecialchars($this->csrf->token(), ENT_QUOTES),
            ), ['is_safe' => ['html']]),
        ];
    }
}
