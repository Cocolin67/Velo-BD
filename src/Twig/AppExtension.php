<?php

declare(strict_types=1);

namespace App\Twig;

use App\Support\Flash;
use Twig\Extension\AbstractExtension;
use Twig\TwigFilter;
use Twig\TwigFunction;

/**
 * Filtres et fonctions Twig propres à l'application (libellés, formats français, messages flash).
 */
final class AppExtension extends AbstractExtension
{
    /** Libellés lisibles des valeurs ENUM de la base */
    private const LABELS = [
        'en_service'     => 'En service',
        'hors_service'   => 'Hors service',
        'en_travaux'     => 'En travaux',
        'fonctionnelle'  => 'Fonctionnelle',
        'disponible'     => 'Disponible',
        'en_location'    => 'En location',
        'en_atelier'     => 'En atelier',
        'defectueux'     => 'Défectueux',
        'borne'          => 'Sur borne',
        'mecanique'      => 'Mécanique',
        'electrique'     => 'Électrique',
        'actif'          => 'Actif',
        'expire'         => 'Expiré',
        'resilie'        => 'Résilié',
        'ouvert'         => 'Ouvert',
        'pris_en_charge' => 'Pris en charge',
        'clos'           => 'Clos',
        'en_attente'     => 'En attente',
        'payee'          => 'Payée',
        'echouee'        => 'Échouée',
        'remboursee'     => 'Remboursée',
        'usager'         => 'Usager',
        'operateur'      => 'Opérateur',
        'administrateur' => 'Administrateur',
        'regulation'     => 'Régulation',
        'maintenance'    => 'Maintenance',
        'vide'           => 'Vide',
        'pleine'         => 'Pleine',
    ];

    /** Couleur de badge associée à chaque valeur */
    private const TONES = [
        'en_service' => 'green', 'fonctionnelle' => 'green', 'disponible' => 'green', 'actif' => 'green',
        'payee' => 'green', 'clos' => 'zinc', 'borne' => 'green',
        'en_location' => 'blue', 'pris_en_charge' => 'blue', 'electrique' => 'blue', 'administrateur' => 'blue',
        'en_travaux' => 'amber', 'en_atelier' => 'amber', 'en_attente' => 'amber', 'ouvert' => 'amber',
        'operateur' => 'amber', 'vide' => 'amber',
        'hors_service' => 'red', 'defectueux' => 'red', 'resilie' => 'red', 'echouee' => 'red', 'pleine' => 'red',
    ];

    public function __construct(private readonly Flash $flash)
    {
    }

    public function getFunctions(): array
    {
        return [
            new TwigFunction('flashes', fn (): array => $this->flash->consume()),
        ];
    }

    public function getFilters(): array
    {
        return [
            new TwigFilter('label', static fn (?string $v): string => $v === null ? '—' : (self::LABELS[$v] ?? ucfirst(str_replace('_', ' ', $v)))),
            new TwigFilter('tone', static fn (?string $v): string => self::TONES[$v] ?? 'zinc'),
            new TwigFilter('money', static fn (mixed $v): string => $v === null ? '—' : number_format((float) $v, 2, ',', "\u{202F}") . "\u{00A0}€"),
            new TwigFilter('num', static fn (mixed $v, int $dec = 0): string => $v === null ? '—' : number_format((float) $v, $dec, ',', "\u{202F}")),
            new TwigFilter('pct', static fn (mixed $v, int $dec = 0): string => $v === null ? '—' : number_format((float) $v * 100, $dec, ',', "\u{202F}") . "\u{00A0}%"),
            new TwigFilter('dt', [self::class, 'formatDateTime']),
            new TwigFilter('d', [self::class, 'formatDate']),
            new TwigFilter('duration', [self::class, 'formatDuration']),
        ];
    }

    public static function formatDateTime(mixed $value): string
    {
        $date = self::toDate($value);

        return $date ? $date->format('d/m/Y H:i') : '—';
    }

    public static function formatDate(mixed $value): string
    {
        $date = self::toDate($value);

        return $date ? $date->format('d/m/Y') : '—';
    }

    /** 75 → « 1 h 15 » ; 12 → « 12 min » */
    public static function formatDuration(mixed $minutes): string
    {
        if ($minutes === null || $minutes === '') {
            return '—';
        }
        $m = (int) $minutes;

        return $m < 60 ? $m . "\u{00A0}min" : sprintf("%d\u{00A0}h\u{00A0}%02d", intdiv($m, 60), $m % 60);
    }

    private static function toDate(mixed $value): ?\DateTimeInterface
    {
        if ($value instanceof \DateTimeInterface) {
            return $value;
        }
        if (!is_string($value) || $value === '') {
            return null;
        }
        try {
            return new \DateTimeImmutable($value);
        } catch (\Exception) {
            return null;
        }
    }
}
