<?php

declare(strict_types=1);

namespace App\Support;

/**
 * Cache fichier minimal (un fichier par clé dans var/cache/app), avec durée de vie.
 *
 * Sert à ne pas recalculer à chaque affichage les statistiques coûteuses
 * (procédures sp_stat_*), qui portent sur des millions de lignes mais évoluent peu.
 * Les valeurs sont sérialisées sans objets (allowed_classes = false) : un fichier
 * de cache modifié ne peut pas instancier de classe PHP.
 */
final class Cache
{
    public function __construct(private readonly string $dir)
    {
    }

    /**
     * Renvoie la valeur en cache, ou la calcule avec $compute et la stocke $ttl secondes.
     *
     * @template T
     * @param callable(): T $compute
     * @param bool          $hit     vaut true en sortie si la valeur venait du cache
     * @param bool          $refresh true : ignore la valeur en cache et la recalcule
     * @return T
     */
    public function remember(string $key, int $ttl, callable $compute, ?bool &$hit = null, bool $refresh = false): mixed
    {
        $file = $this->path($key);
        $raw  = !$refresh && is_file($file) ? @file_get_contents($file) : false;
        if ($raw !== false) {
            $entry = @unserialize($raw, ['allowed_classes' => false]);
            if (is_array($entry) && ($entry['expires'] ?? 0) > time() && array_key_exists('value', $entry)) {
                $hit = true;

                return $entry['value'];
            }
        }

        $hit   = false;
        $value = $compute();
        $this->write($file, serialize(['expires' => time() + $ttl, 'value' => $value]));

        return $value;
    }

    /** Supprime toutes les entrées dont la clé commence par $prefix. */
    public function clear(string $prefix = ''): void
    {
        foreach (glob($this->dir . '/' . self::safe($prefix) . '*.cache') ?: [] as $file) {
            @unlink($file);
        }
    }

    private function path(string $key): string
    {
        // Préfixe lisible (pour clear) + empreinte de la clé complète
        $prefix = self::safe(strtok($key, ':') ?: 'cache');

        // (« - » et non « : », interdit dans les noms de fichiers sous Windows)
        return sprintf('%s/%s-%s.cache', $this->dir, $prefix, hash('xxh128', $key));
    }

    private static function safe(string $s): string
    {
        return preg_replace('/[^a-z0-9_]/i', '_', $s) ?? '';
    }

    /** Écriture atomique (fichier temporaire puis renommage) ; un échec n'est pas bloquant. */
    private function write(string $file, string $data): void
    {
        if (!is_dir($this->dir) && !@mkdir($this->dir, 0775, true) && !is_dir($this->dir)) {
            return;
        }
        $tmp = $file . '.' . bin2hex(random_bytes(4)) . '.tmp';
        if (@file_put_contents($tmp, $data, LOCK_EX) !== false && !@rename($tmp, $file)) {
            @unlink($tmp);
        }
    }
}
