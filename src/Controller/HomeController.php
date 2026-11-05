<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\Database;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

final class HomeController extends Controller
{
    public function __construct(Twig $view, Flash $flash, private readonly Database $db)
    {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        // Chiffres publics du réseau (vue v_stations_occupation, temps réel)
        $network = $this->db->fetchOne(
            "SELECT COUNT(*)                         AS stations,
                    COALESCE(SUM(nb_velos_disponibles), 0) AS velos_disponibles,
                    COALESCE(SUM(nb_velos_electriques), 0) AS velos_electriques,
                    COALESCE(SUM(nb_bornes_libres), 0)     AS bornes_libres
               FROM v_stations_occupation
              WHERE etat_station = 'en_service'"
        );

        return $this->render($response, 'home.twig', ['network' => $network]);
    }
}
