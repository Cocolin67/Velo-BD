<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\BusinessException;
use App\Repository\UserRepository;
use App\Security\Auth;
use App\Support\Flash;
use App\Support\Sort;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

/** Administration des comptes : recherche et création d'opérateurs / administrateurs. */
final class AdminUserController extends Controller
{
    private const ROLES = [Auth::USAGER, Auth::OPERATEUR, Auth::ADMIN];

    public function __construct(Twig $view, Flash $flash, private readonly UserRepository $users)
    {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        $query   = $request->getQueryParams();
        $filters = ['q' => self::str($query, 'q', 100), 'role' => self::oneOf($query, 'role', self::ROLES)];
        $tri     = Sort::fromQuery($query, array_keys(UserRepository::SORTABLE));
        $page    = self::page($query);
        $result  = $this->users->search($filters['q'], $filters['role'], $page, self::PER_PAGE, $tri);

        return $this->render($response, 'admin/users/index.twig', [
            'users'    => $result['rows'],
            'has_next' => $result['has_next'],
            'page'     => $page,
            'filters'  => $filters,
            'query'    => array_filter($filters) + $tri->params(),
            'tri'      => $tri->view('admin.users', array_filter($filters)),
            'counts'   => $this->users->countByRole(),
        ]);
    }

    public function createForm(Request $request, Response $response): Response
    {
        return $this->render($response, 'admin/users/form.twig', ['old' => ['specialite' => 'regulation']]);
    }

    public function create(Request $request, Response $response): Response
    {
        $data = $this->form($request);
        $old  = [
            'nom'        => self::str($data, 'nom', 100),
            'prenom'     => self::str($data, 'prenom', 100),
            'email'      => mb_strtolower(self::str($data, 'email')),
            'matricule'  => mb_strtoupper(self::str($data, 'matricule', 20)),
            'specialite' => self::oneOf($data, 'specialite', ['regulation', 'maintenance'], 'regulation'),
            'est_admin'  => isset($data['est_admin']),
        ];
        $password = is_string($data['password'] ?? null) ? $data['password'] : '';
        $confirm  = is_string($data['password_confirm'] ?? null) ? $data['password_confirm'] : '';

        $errors = [];
        if ($old['nom'] === '' || $old['prenom'] === '') {
            $errors['nom'] = 'Nom et prénom sont obligatoires.';
        }
        if (!filter_var($old['email'], FILTER_VALIDATE_EMAIL)) {
            $errors['email'] = 'Adresse email invalide.';
        }
        if (!preg_match('/^[A-Z0-9-]{3,20}$/', $old['matricule'])) {
            $errors['matricule'] = '3 à 20 caractères : lettres, chiffres ou tirets.';
        }
        $errors += AuthController::checkPassword($password, $confirm);

        if (!$errors) {
            try {
                $this->users->createOperator(
                    $old['nom'], $old['prenom'], $old['email'], password_hash($password, PASSWORD_DEFAULT),
                    $old['matricule'], $old['specialite'], $old['est_admin'],
                );
                $this->flash->success(sprintf('Compte %s créé pour %s %s.', $old['est_admin'] ? 'administrateur' : 'opérateur', $old['prenom'], $old['nom']));

                return $this->redirect($request, $response, 'admin.users');
            } catch (BusinessException $e) {
                $errors['email'] = $e->getMessage();   // « Email ou matricule déjà utilisé »
            }
        }

        return $this->render($response->withStatus(422), 'admin/users/form.twig', ['old' => $old, 'errors' => $errors]);
    }
}
