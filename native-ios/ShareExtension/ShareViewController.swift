import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let appGroup = "group.com.deaum.numbermemo"
    private let notifyName = "com.deaum.numbermemo.share" as CFString

    private struct FolderItem {
        let id: Int64
        let name: String
        let color: Int64
    }

    private let headerCard = UIView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var collectedText = ""
    private var detectedIds: [Int64] = []
    private var folders: [FolderItem] = []
    private var isSaving = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavBar()
        setupHeaderCard()
        setupTableView()

        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        spinner.startAnimating()

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task {
            await processIncomingShare()
        }
    }

    private func setupNavBar() {
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let navItem = UINavigationItem(title: L10n.text("Number Memo"))

        navItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.text("Cancel"),
            style: .plain,
            target: self,
            action: #selector(cancel)
        )

        let addFolderBtn = UIBarButtonItem(
            image: UIImage(systemName: "folder.badge.plus"),
            style: .plain,
            target: self,
            action: #selector(promptNewFolder)
        )
        addFolderBtn.accessibilityLabel = L10n.text("Create Folder")
        navItem.rightBarButtonItem = addFolderBtn

        navBar.items = [navItem]
        view.addSubview(navBar)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupHeaderCard() {
        headerCard.translatesAutoresizingMaskIntoConstraints = false
        headerCard.backgroundColor = .secondarySystemGroupedBackground
        headerCard.layer.cornerRadius = 14
        headerCard.layer.masksToBounds = true
        view.addSubview(headerCard)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "bookmark.circle.fill")
        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit
        headerCard.addSubview(iconImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.text = L10n.text("Analyzing…")
        headerCard.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.text = L10n.text("Analyzing shared items")
        headerCard.addSubview(subtitleLabel)

        guard let navBar = view.subviews.first(where: { $0 is UINavigationBar }) else { return }

        NSLayoutConstraint.activate([
            headerCard.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: 12),
            headerCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            headerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            iconImageView.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 14),
            iconImageView.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 36),
            iconImageView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -12)
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "folderCell")
        tableView.isHidden = true
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 6),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func processIncomingShare() async {
        let text = await extractTextFromExtensionContext()
        self.collectedText = text
        self.detectedIds = parseGalleryIds(text)
        self.folders = loadFolders()

        await MainActor.run {
            spinner.stopAnimating()
            spinner.isHidden = true

            if detectedIds.isEmpty {
                titleLabel.text = L10n.text("No Work Number")
                subtitleLabel.text = L10n.text("No work numbers were found in the shared link or text.")
                iconImageView.image = UIImage(systemName: "exclamationmark.circle.fill")
                iconImageView.tintColor = .systemOrange
                return
            }

            let idStrings = detectedIds.map { String($0) }.joined(separator: "  ")
            titleLabel.text = detectedIds.count == 1
                ? L10n.text("Save Work Number %@", String(describing: String(detectedIds[0])))
                : L10n.text("Save %@ Work Numbers", String(describing: detectedIds.count))
            subtitleLabel.text = L10n.text("Choose a folder to save to (%@)", String(describing: idStrings))
            iconImageView.image = UIImage(systemName: "bookmark.circle.fill")
            iconImageView.tintColor = .systemBlue

            tableView.isHidden = false
            tableView.reloadData()
        }
    }

    private func extractTextFromExtensionContext() async -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return "" }
        var collected = ""

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                       let url = item as? URL {
                        collected += " " + url.absoluteString
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                       let str = item as? String {
                        collected += " " + str
                    }
                }
            }
        }

        return collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseGalleryIds(_ text: String) -> [Int64] {
        let pattern = #"hitomi(?:\.la|-la\.translate\.goog)/(?:galleries|reader)/(\d{4,10})(?:\.html)?|hitomi(?:\.la|-la\.translate\.goog)/[^/\s]+/[^/\s]*-(\d{4,10})\.html"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var ids: [Int64] = []
        for match in matches {
            if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                if let id = Int64(ns.substring(with: match.range(at: 1))) { ids.append(id) }
            } else if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                if let id = Int64(ns.substring(with: match.range(at: 2))) { ids.append(id) }
            }
        }
        if !ids.isEmpty { return ids }

        for token in text.components(separatedBy: CharacterSet(charactersIn: " \t\r\n,;")) {
            if let id = Int64(token), id >= 1000, id <= 9_999_999_999 {
                ids.append(id)
            }
        }
        return ids
    }

    private func loadFolders() -> [FolderItem] {
        var res: [FolderItem] = []

        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let file = container.appendingPathComponent("folders.json")
            if let data = try? Data(contentsOf: file),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in list {
                    if let id = (item["id"] as? NSNumber)?.int64Value,
                       let name = item["name"] as? String {
                        let color = (item["color"] as? NSNumber)?.int64Value ?? 4280391411
                        res.append(FolderItem(id: id, name: name, color: color))
                    }
                }
            }
        }

        if res.isEmpty, let defaults = UserDefaults(suiteName: appGroup),
           let jsonStr = defaults.string(forKey: "folders_json"),
           let data = jsonStr.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list {
                if let id = (item["id"] as? NSNumber)?.int64Value,
                   let name = item["name"] as? String {
                    let color = (item["color"] as? NSNumber)?.int64Value ?? 4280391411
                    res.append(FolderItem(id: id, name: name, color: color))
                }
            }
        }

        return res.isEmpty ? [FolderItem(id: 1, name: "미분류", color: 4280391411)] : res
    }

    @objc private func promptNewFolder() {
        let alert = UIAlertController(title: L10n.text("Create Folder"), message: L10n.text("Enter a folder name"), preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = L10n.text("Folder Name")
            textField.autocapitalizationType = .none
        }

        alert.addAction(UIAlertAction(title: L10n.text("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.text("Save"), style: .default, handler: { [weak self] _ in
            guard let self = self,
                  let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            self.saveAndDismiss(folderId: nil, newFolderName: name)
        }))

        present(alert, animated: true)
    }

    // MARK: - TableView

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L10n.text("Choose Destination Folder")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        folders.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "folderCell", for: indexPath)
        let folder = folders[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = L10n.folderName(folder.name)
        config.textProperties.font = .preferredFont(forTextStyle: .body)

        // Dot image for folder color
        let color = uiColorFromArgb(folder.color)
        let dotConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let circleImage = UIImage(systemName: "circle.fill", withConfiguration: dotConfig)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        config.image = circleImage

        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSaving else { return }
        isSaving = true

        let folder = folders[indexPath.row]
        saveAndDismiss(folderId: folder.id, newFolderName: nil)
    }

    private func saveAndDismiss(folderId: Int64?, newFolderName: String?) {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let pendingFile = container.appendingPathComponent("pending_share.json")
            var payload: [String: Any] = [
                "text": collectedText,
                "created_at": ISO8601DateFormatter().string(from: Date())
            ]
            if let folderId {
                payload["folder_id"] = folderId
            }
            if let newFolderName {
                payload["new_folder_name"] = newFolderName
            }

            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: pendingFile, options: .atomic)
            }

            // Post Darwin notification
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(notifyName),
                nil,
                nil,
                true
            )
        }

        #if os(iOS) && !targetEnvironment(macCatalyst)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func cancel() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func uiColorFromArgb(_ argb: Int64) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a == 0 ? 1.0 : a)
    }
}
