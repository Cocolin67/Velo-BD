<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\UserRepository;
use App\Security\Auth;
use App\Support\Flash;
use App\Support\Session;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

final class AuthController extends Controller
{
    private const MAX_ATTEMPTS = 5;     // échecs avant blocage temporaire
    private const LOCK_SECONDS = 60;

    // Hash bcrypt quelconque : la vérification prend le même temps que l'email existe ou non
    private const DUMMY_HASH = '$2y$12$FB6YDEohtnAKI0RBchd1l.rB6J2YpvqbpplL78I9WKVc/wWEt2XFK';

    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Auth $auth,
        private readonly Session $session,
        private readonly UserRepository $users,
    ) {
        parent::__construct($view, $flash);
    }

    public function loginForm(Request $request, Response $response): Response
    {
        if ($this->auth->check()) {
            return $this->redirect($request, $response, 'home');
        }

        return $this->render($response, 'auth/login.twig');
    }

    public function login(Request $request, Response $response): Response
    {
        $data     = $this->form($request);
        $email    = mb_strtolower(self::str($data, 'email'));
        $password = is_string($data['password'] ?? null) ? $data['password'] : '';

        $lockedUntil = (int) $this->session->get('_login_locked_until', 0);
        if ($lockedUntil > time()) {
            $this->flash->error(sprintf('Trop de tentatives. Réessayez dans %d secondes.', $lockedUntil - time()));

            return $this->redirect($request, $response, 'login');
        }

        $user = $email !== '' ? $this->users->findForLogin($email) : null;
        $ok   = password_verify($password, $user['mot_de_passe_hash'] ?? self::DUMMY_HASH)
             && $user !== null && $user['role'] !== null;

        if (!$ok) {
            $fails = (int) $this->session->get('_login_fails', 0) + 1;
            $this->session->set('_login_fails', $fails);
            if ($fails >= self::MAX_ATTEMPTS) {
                $this->session->set('_login_locked_until', time() + self::LOCK_SECONDS);
                $this->session->set('_login_fails', 0);
            }
            // Message volontairement identique : on ne révèle pas si l'email existe
            return $this->render($response->withStatus(422), 'auth/login.twig', [
                'error' => 'Email ou mot de passe incorrect.',
                'old'   => ['email' => $email],
            ]);
        }

        // Coût de hachage relevé depuis la création du compte : on met le hash à jour
        if (password_needs_rehash($user['mot_de_passe_hash'], PASSWORD_DEFAULT)) {
            $this->users->updatePasswordHash((int) $user['id_utilisateur'], password_hash($password, PASSWORD_DEFAULT));
        }

        $this->session->remove('_login_fails');
        $this->session->remove('_login_locked_until');
        $this->auth->login($user, $email);
        $this->flash->success(sprintf('Bonjour %s !', $user['prenom']));

        return $this->redirect($request, $response, 'home');
    }

    public function registerForm(Request $request, Response $response): Response
    {
        if ($this->auth->check()) {
            return $this->redirect($request, $response, 'home');
        }

        return $this->render($response, 'auth/register.twig');
    }

    public function register(Request $request, Response $response): Response
    {
        $data = $this->form($request);
        $old  = [
            'nom'            => self::str($data, 'nom', 100),
            'prenom'         => self::str($data, 'prenom', 100),
            'email'          => mb_strtolower(self::str($data, 'email')),
            'telephone'      => self::str($data, 'telephone', 20),
            'date_naissance' => self::str($data, 'date_naissance', 10),
        ];
        $password = is_string($data['password'] ?? null) ? $data['password'] : '';
        $confirm  = is_string($data['password_confirm'] ?? null) ? $data['password_confirm'] : '';

        $errors = [];
        if ($old['nom'] === '') {
            $errors['nom'] = 'Le nom est obligatoire.';
        }
        if ($old['prenom'] === '') {
            $errors['prenom'] = 'Le prénom est obligatoire.';
        }
        if (!filter_var($old['email'], FILTER_VALIDATE_EMAIL)) {
            $errors['email'] = 'Adresse email invalide.';
        }
        if ($old['telephone'] !== '' && !preg_match('/^\+?[0-9 .-]{6,20}$/', $old['telephone'])) {
            $errors['telephone'] = 'Numéro de téléphone invalide.';
        }
        $naissance = $old['date_naissance'] === '' ? null : self::date($old, 'date_naissance');
        if ($old['date_naissance'] !== '' && ($naissance === null || $naissance > date('Y-m-d'))) {
            $errors['date_naissance'] = 'Date de naissance invalide.';
        }
        $errors += self::checkPassword($password, $confirm);

        if (!$errors) {
            try {
                $id = $this->users->registerUsager(
                    $old['nom'], $old['prenom'], $old['email'],
                    password_hash($password, PASSWORD_DEFAULT),
                    $naissance, $old['telephone'] ?: null,
                );
                $this->auth->login([
                    'id_utilisateur' => $id, 'nom' => $old['nom'], 'prenom' => $old['prenom'], 'role' => Auth::USAGER,
                ], $old['email']);
                $this->flash->success('Bienvenue ! Souscrivez un abonnement pour emprunter votre premier vélo.');

                return $this->redirect($request, $response, 'home');
            } catch (BusinessException $e) {
                $errors['email'] = $e->getMessage();   // « Cet email est déjà utilisé »
            }
        }

        return $this->render($response->withStatus(422), 'auth/register.twig', ['errors' => $errors, 'old' => $old]);
    }

    public function logout(Request $request, Response $response): Response
    {
        $this->auth->logout();
        $this->flash->info('Vous êtes déconnecté.');

        return $this->redirect($request, $response, 'home');
    }

    /** @return array<string, string> */
    public static function checkPassword(string $password, string $confirm): array
    {
        if (mb_strlen($password) < 8 || !preg_match('/\d/', $password) || !preg_match('/\pL/u', $password)) {
            return ['password' => 'Au moins 8 caractères, dont une lettre et un chiffre.'];
        }
        if (strlen($password) > 72) {
            return ['password' => '72 caractères maximum.'];   // limite de bcrypt
        }
        if (!hash_equals($password, $confirm)) {
            return ['password_confirm' => 'Les deux mots de passe ne correspondent pas.'];
        }

        return [];
    }
}
