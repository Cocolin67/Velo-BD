<?php

declare(strict_types=1);

use App\Database\Database;
use App\Repository\StatsRepository;
use App\Support\Cache;
use App\Twig\AppExtension;
use App\Twig\SecurityExtension;
use Psr\Container\ContainerInterface;
use Psr\Http\Message\ResponseFactoryInterface;
use Slim\Psr7\Factory\ResponseFactory;
use Slim\Views\Twig;

// Définitions du conteneur PHP-DI. Les contrôleurs et services sont autowirés.
return [
    'settings' => static fn (): array => require __DIR__ . '/settings.php',

    Database::class => static fn (ContainerInterface $c): Database => new Database($c->get('settings')['db']),

    Cache::class => static fn (ContainerInterface $c): Cache => new Cache($c->get('settings')['cache']['path']),

    StatsRepository::class => static fn (ContainerInterface $c): StatsRepository => new StatsRepository(
        $c->get(Database::class), $c->get(Cache::class), $c->get('settings')['cache']['ttl'],
    ),

    ResponseFactoryInterface::class =>static fn (): ResponseFactoryInterface => new ResponseFactory(),

    Twig::class => static function (ContainerInterface $c): Twig {
        $settings = $c->get('settings');
        $twig     = Twig::create($settings['twig']['path'], [
            'cache'            => $settings['twig']['cache'],
            'strict_variables' => $settings['app']['debug'],
            'autoescape'       => 'html',   // échappement systématique contre le XSS
        ]);
        $twig->addExtension($c->get(AppExtension::class));
        $twig->addExtension($c->get(SecurityExtension::class));
        $twig->getEnvironment()->addGlobal('app_name', $settings['app']['name']);

        return $twig;
    },
];
