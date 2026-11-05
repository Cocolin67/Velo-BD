<?php

declare(strict_types=1);

namespace App\Support;

/** Messages affichés une seule fois, après une redirection (modèle Post/Redirect/Get). */
final class Flash
{
    private const KEY = '_flash';

    public function __construct(private readonly Session $session)
    {
    }

    public function success(string $message): void
    {
        $this->add('success', $message);
    }

    public function error(string $message): void
    {
        $this->add('error', $message);
    }

    public function info(string $message): void
    {
        $this->add('info', $message);
    }

    /** @return list<array{type: string, message: string}> messages en attente, puis vidés */
    public function consume(): array
    {
        $messages = $this->session->get(self::KEY, []);
        $this->session->remove(self::KEY);

        return $messages;
    }

    private function add(string $type, string $message): void
    {
        $messages   = $this->session->get(self::KEY, []);
        $messages[] = ['type' => $type, 'message' => $message];
        $this->session->set(self::KEY, $messages);
    }
}
