<?php

declare(strict_types=1);

namespace App\Controller;

use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Routing\RouteContext;
use Slim\Views\Twig;

/** Outils communs aux contrôleurs : rendu Twig, redirections, lecture des formulaires. */
abstract class Controller
{
    public function __construct(
        protected readonly Twig $view,
        protected readonly Flash $flash,
    ) {
    }

    protected function render(Response $response, string $template, array $data = []): Response
    {
        return $this->view->render($response, $template, $data);
    }

    /** Redirection 303 (Post/Redirect/Get) vers une route nommée. */
    protected function redirect(Request $request, Response $response, string $route, array $args = [], array $query = []): Response
    {
        $url = RouteContext::fromRequest($request)->getRouteParser()->urlFor($route, $args, $query);

        return $response->withHeader('Location', $url)->withStatus(303);
    }

    /** @return array<string, mixed> */
    protected function form(Request $request): array
    {
        return (array) ($request->getParsedBody() ?? []);
    }

    protected static function str(array $data, string $key, int $max = 255): string
    {
        $value = $data[$key] ?? '';

        return is_string($value) ? mb_substr(trim($value), 0, $max) : '';
    }

    protected static function int(array $data, string $key): ?int
    {
        $value = $data[$key] ?? null;
        if (is_int($value)) {
            return $value;
        }

        return is_string($value) && preg_match('/^\d{1,10}$/', $value) ? (int) $value : null;
    }

    /** Valeur autorisée parmi une liste blanche, sinon $default. */
    protected static function oneOf(array $data, string $key, array $allowed, ?string $default = null): ?string
    {
        $value = $data[$key] ?? null;

        return is_string($value) && in_array($value, $allowed, true) ? $value : $default;
    }

    /** Date au format AAAA-MM-JJ, sinon null. */
    protected static function date(array $data, string $key): ?string
    {
        $value = $data[$key] ?? null;
        if (!is_string($value)) {
            return null;
        }
        $d = \DateTimeImmutable::createFromFormat('!Y-m-d', $value);

        return $d && $d->format('Y-m-d') === $value ? $value : null;
    }

    protected static function page(array $query): int
    {
        return max(1, min(10000, self::int($query, 'page') ?? 1));
    }
}
