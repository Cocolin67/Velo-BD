<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\UserRepository;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

final class ProfileController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Auth $auth,
        private readonly UserRepository $users,
    ) {
        parent::__construct($view, $flash);
    }

    public function show(Request $request, Response $response): Response
    {
        return $this->render($response, 'profile.twig', [
            'profile' => $this->users->findProfile((int) $this->auth->id()),
        ]);
    }

    public function update(Request $request, Response $response): Response
    {
        $data = $this->form($request);
        $old  = [
            'nom'            => self::str($data, 'nom', 100),
            'prenom'         => self::str($data, 'prenom', 100),
            'email'          => mb_strtolower(self::str($data, 'email')),
            'telephone'      => self::str($data, 'telephone', 20),
            'date_naissance' => self::str($data, 'date_naissance', 10),
        ];

        $errors = [];
        if ($old['nom'] === '' || $old['prenom'] === '') {
            $errors['nom'] = 'Nom et prénom sont obligatoires.';
        }
        if (!filter_var($old['email'], FILTER_VALIDATE_EMAIL)) {
            $errors['email'] = 'Adresse email invalide.';
        }
        if ($old['telephone'] !== '' && !preg_match('/^\+?[0-9 .-]{6,20}$/', $old['telephone'])) {
            $errors['telephone'] = 'Numéro de téléphone invalide.';
        }
        $naissance = $old['date_naissance'] === '' ? null : self::date($old, 'date_naissance');
        if ($old['date_naissance'] !== '' && $naissance === null) {
            $errors['date_naissance'] = 'Date de naissance invalide.';
        }

        if (!$errors) {
            try {
                $this->users->updateProfile(
                    (int) $this->auth->id(), $old['nom'], $old['prenom'], $old['email'],
                    $this->auth->isUsager(), $old['telephone'] ?: null, $naissance,
                );
                $this->auth->refresh($old['nom'], $old['prenom'], $old['email']);
                $this->flash->success('Profil mis à jour.');

                return $this->redirect($request, $response, 'profile');
            } catch (BusinessException $e) {
                $errors['email'] = $e->getMessage();
            }
        }

        $profile = array_merge($this->users->findProfile((int) $this->auth->id()) ?? [], $old);

        return $this->render($response->withStatus(422), 'profile.twig', ['profile' => $profile, 'errors' => $errors]);
    }

    public function password(Request $request, Response $response): Response
    {
        $data    = $this->form($request);
        $current = is_string($data['current'] ?? null) ? $data['current'] : '';
        $new     = is_string($data['password'] ?? null) ? $data['password'] : '';
        $confirm = is_string($data['password_confirm'] ?? null) ? $data['password_confirm'] : '';
        $profile = $this->users->findProfile((int) $this->auth->id());

        $errors = [];
        if (!$profile || !password_verify($current, $profile['mot_de_passe_hash'])) {
            $errors['current'] = 'Mot de passe actuel incorrect.';
        } else {
            $errors = AuthController::checkPassword($new, $confirm);
        }

        if ($errors) {
            return $this->render($response->withStatus(422), 'profile.twig', ['profile' => $profile, 'pwd_errors' => $errors]);
        }

        $this->users->updatePasswordHash((int) $this->auth->id(), password_hash($new, PASSWORD_DEFAULT));
        $this->flash->success('Mot de passe modifié.');

        return $this->redirect($request, $response, 'profile');
    }
}
