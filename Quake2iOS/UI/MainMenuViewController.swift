/*
 * MainMenuViewController.swift
 * Native loading screen that transitions to GameViewController once the engine is ready
 */

import UIKit

class MainMenuViewController: UIViewController {

    private let titleLabel = UILabel()
    private let loadingLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let startButton = UIButton(type: .system)

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkGameData()
    }

    // MARK: - UI Setup

    private func setupUI() {
        titleLabel.text = "QUAKE II"
        titleLabel.textColor = UIColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1.0)
        titleLabel.font = .boldSystemFont(ofSize: 48)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        loadingLabel.text = "Checking game data..."
        loadingLabel.textColor = .lightGray
        loadingLabel.font = .systemFont(ofSize: 16)
        loadingLabel.textAlignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingLabel)

        activityIndicator.color = .white
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)

        startButton.setTitle("START GAME", for: .normal)
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 20)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = UIColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1.0)
        startButton.layer.cornerRadius = 12
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.isHidden = true
        startButton.addTarget(self, action: #selector(startGame), for: .touchUpInside)
        view.addSubview(startButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),

            loadingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 30),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: loadingLabel.bottomAnchor, constant: 16),

            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 40),
            startButton.widthAnchor.constraint(equalToConstant: 200),
            startButton.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    // MARK: - Game Data Check

    private func checkGameData() {
        let basePath = Bundle.main.resourcePath! + "/baseq2"
        let pakFile = basePath + "/pak0.pak"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = FileManager.default.fileExists(atPath: pakFile)
            DispatchQueue.main.async {
                self?.activityIndicator.stopAnimating()
                if exists {
                    self?.loadingLabel.isHidden = true
                    self?.startButton.isHidden = false
                } else {
                    self?.loadingLabel.text = "Game data not found.\nPlace pak0.pak in baseq2/ folder."
                    self?.loadingLabel.numberOfLines = 0
                    self?.loadingLabel.textColor = .systemRed
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func startGame() {
        let gameVC = GameViewController()
        gameVC.modalPresentationStyle = .fullScreen
        gameVC.modalTransitionStyle = .crossDissolve
        present(gameVC, animated: true)
    }
}
