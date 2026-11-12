<?php

declare(strict_types=1);

namespace App\Support;

/**
 * Tri d'un tableau par clic sur l'en-tête d'une colonne.
 *
 * Le tri voyage dans l'URL : ?tri=<colonne>&ordre=asc|desc. Plusieurs tableaux sur une même
 * page utilisent un suffixe (tri_od, ordre_od...). Seules les colonnes déclarées par le
 * contrôleur sont acceptées : la valeur de l'URL ne sert qu'à choisir une expression SQL
 * écrite en dur, jamais à construire la requête.
 *
 * Sans tri choisi, l'ordre par défaut de chaque écran est conservé.
 */
final class Sort
{
    private function __construct(
        public readonly ?string $key,
        public readonly string $dir,
        public readonly string $suffix,
    ) {
    }

    /** @param list<string> $keys colonnes triables */
    public static function fromQuery(array $query, array $keys, string $suffix = ''): self
    {
        $key = $query['tri' . $suffix] ?? null;
        if (!is_string($key) || !in_array($key, $keys, true)) {
            return new self(null, 'asc', $suffix);
        }

        return new self($key, ($query['ordre' . $suffix] ?? 'asc') === 'desc' ? 'desc' : 'asc', $suffix);
    }

    public function active(): bool
    {
        return $this->key !== null;
    }

    /** Paramètres d'URL du tri courant, à conserver dans la pagination. */
    public function params(): array
    {
        return $this->key === null ? [] : ['tri' . $this->suffix => $this->key, 'ordre' . $this->suffix => $this->dir];
    }

    /**
     * Clause ORDER BY.
     *
     * @param array<string, string|list<string>> $columns  colonne => expression(s) SQL
     * @param string       $default   ordre de l'écran quand aucun tri n'est choisi
     * @param string       $tieBreak  départage les égalités : ordre stable d'une page à l'autre
     * @param list<string> $nullable  colonnes pouvant valoir NULL : ces lignes restent en fin de liste
     */
    public function orderBy(array $columns, string $default, string $tieBreak, array $nullable = []): string
    {
        if ($this->key === null || !isset($columns[$this->key])) {
            return $default;
        }
        $dir   = $this->dir === 'desc' ? 'DESC' : 'ASC';
        $parts = [];
        foreach ((array) $columns[$this->key] as $expr) {
            if (in_array($this->key, $nullable, true)) {
                $parts[] = "($expr IS NULL)";
            }
            $parts[] = "$expr $dir";
        }

        return implode(', ', $parts) . ', ' . $tieBreak;
    }

    /**
     * Tri d'un résultat déjà calculé (statistiques paginées en PHP).
     * Nombres comparés comme des nombres, textes dans l'ordre alphabétique français ; NULL en fin de liste.
     *
     * @param array<string, string> $fields colonne => clé de la ligne
     */
    public function apply(array $rows, array $fields): array
    {
        if ($this->key === null || !isset($fields[$this->key])) {
            return $rows;
        }
        $field    = $fields[$this->key];
        $sign     = $this->dir === 'desc' ? -1 : 1;
        $collator = class_exists(\Collator::class) ? new \Collator('fr_FR') : null;

        usort($rows, static function (array $a, array $b) use ($field, $sign, $collator): int {
            $x = $a[$field] ?? null;
            $y = $b[$field] ?? null;
            if ($x === null || $y === null) {
                return ($x === null) <=> ($y === null);
            }
            if (is_numeric($x) && is_numeric($y)) {
                return $sign * ((float) $x <=> (float) $y);
            }

            return $sign * ($collator ? (int) $collator->compare((string) $x, (string) $y) : strnatcasecmp((string) $x, (string) $y));
        });

        return $rows;
    }

    /**
     * Données pour la macro ui.th : de quoi construire les liens de tri et de réinitialisation.
     * $query = paramètres d'URL à conserver (filtres...). Le tri et la page de ce tableau en sont
     * retirés : changer de tri revient à la première page.
     */
    public function view(string $route, array $query, string $pageParam = 'page', ?string $anchor = null, array $args = []): array
    {
        unset($query['tri' . $this->suffix], $query['ordre' . $this->suffix], $query[$pageParam]);

        return [
            'route'  => $route,
            'args'   => $args,
            'query'  => $query,
            'key'    => $this->key,
            'dir'    => $this->dir,
            'suffix' => $this->suffix,
            'anchor' => $anchor,
        ];
    }
}
