import Foundation
import SQLite3

actor LibraryIndexStore {
    private let schemaVersion = 1
    private let databaseURL: URL
    private var database: OpaquePointer?

    init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directoryURL = baseURL
            .appendingPathComponent("MotionAlbum", isDirectory: true)
            .appendingPathComponent("LibraryIndex", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("index.sqlite3")
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func load(folder: URL, recursively: Bool) -> [PhotoFileDescriptor]? {
        do {
            let db = try openDatabase()
            guard let folderID = try folderID(
                in: db,
                folder: folder,
                recursively: recursively,
                createIfNeeded: false
            ) else {
                return nil
            }

            let sql = """
            SELECT path, companion_path, companion_file_size, companion_modified_at,
                   file_size, modified_at, media_kind,
                   make, model, software, captured_at, captured_at_ts,
                   pixel_width, pixel_height, latitude, longitude, live_status
            FROM files
            WHERE folder_id = ?
            ORDER BY path COLLATE NOCASE
            """
            var statement: OpaquePointer?
            try prepare(sql, in: db, statement: &statement)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, folderID)

            var descriptors: [PhotoFileDescriptor] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnString(statement, 0),
                      let mediaKindRaw = columnString(statement, 6),
                      let mediaKind = MediaKind(rawValue: mediaKindRaw) else { continue }

                let metadata = PhotoMetadata(
                    make: columnString(statement, 7),
                    model: columnString(statement, 8),
                    software: columnString(statement, 9),
                    capturedAt: columnString(statement, 10),
                    capturedAtDate: columnDate(statement, 11),
                    pixelWidth: columnInt(statement, 12),
                    pixelHeight: columnInt(statement, 13),
                    latitude: columnDouble(statement, 14),
                    longitude: columnDouble(statement, 15)
                )

                descriptors.append(PhotoFileDescriptor(
                    url: URL(fileURLWithPath: path),
                    companionVideoURL: columnString(statement, 1).map { URL(fileURLWithPath: $0) },
                    companionVideoFileSize: columnInt64(statement, 2),
                    companionVideoModifiedAt: columnDate(statement, 3),
                    fileSize: columnInt64(statement, 4) ?? 0,
                    modifiedAt: columnDate(statement, 5) ?? .distantPast,
                    metadata: metadata,
                    mediaKind: mediaKind,
                    indexedLiveStatus: columnString(statement, 16).flatMap(LivePhotoStatus.init(rawValue:))
                ))
            }
            return descriptors
        } catch {
            AppLogger.warning("读取 SQLite 图库索引失败：\(folder.path)", error: error)
            return nil
        }
    }

    func replaceFolderIndex(
        descriptors: [PhotoFileDescriptor],
        folder: URL,
        recursively: Bool
    ) {
        do {
            let db = try openDatabase()
            let folderID = try folderID(
                in: db,
                folder: folder,
                recursively: recursively,
                createIfNeeded: true
            )!
            let scanID = UUID().uuidString

            try execute("BEGIN IMMEDIATE TRANSACTION", in: db)
            do {
                try upsertDescriptors(
                    descriptors,
                    folderID: folderID,
                    root: folder,
                    scanID: scanID,
                    in: db
                )
                try deleteRowsNotSeen(folderID: folderID, scanID: scanID, in: db)
                try updateFolderScanTime(folderID: folderID, in: db)
                try execute("COMMIT", in: db)
            } catch {
                try? execute("ROLLBACK", in: db)
                throw error
            }
        } catch {
            AppLogger.warning("写入 SQLite 图库索引失败：\(folder.path)", error: error)
        }
    }

    func updateMetadata(_ metadata: PhotoMetadata, for url: URL, folder: URL, recursively: Bool) {
        do {
            let db = try openDatabase()
            guard let folderID = try folderID(
                in: db,
                folder: folder,
                recursively: recursively,
                createIfNeeded: false
            ) else {
                return
            }

            let searchText = [
                url.lastPathComponent,
                url.deletingLastPathComponent().lastPathComponent,
                metadata.deviceText,
                metadata.software,
                metadata.capturedAt,
                metadata.sizeText
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            let sql = """
            UPDATE files
            SET make = ?, model = ?, software = ?, captured_at = ?, captured_at_ts = ?,
                pixel_width = ?, pixel_height = ?, latitude = ?, longitude = ?,
                metadata_indexed_at = ?, search_text = trim(coalesce(search_text, '') || ' ' || ?)
            WHERE folder_id = ? AND path = ?
            """
            var statement: OpaquePointer?
            try prepare(sql, in: db, statement: &statement)
            defer { sqlite3_finalize(statement) }

            bind(statement, 1, metadata.make)
            bind(statement, 2, metadata.model)
            bind(statement, 3, metadata.software)
            bind(statement, 4, metadata.capturedAt)
            bind(statement, 5, metadata.capturedAtDate)
            bind(statement, 6, metadata.pixelWidth)
            bind(statement, 7, metadata.pixelHeight)
            bind(statement, 8, metadata.latitude)
            bind(statement, 9, metadata.longitude)
            bind(statement, 10, Date())
            bind(statement, 11, searchText)
            sqlite3_bind_int64(statement, 12, folderID)
            bind(statement, 13, url.standardizedFileURL.path)
            try stepDone(statement, db: db)
        } catch {
            AppLogger.warning("更新 SQLite 元信息索引失败：\(url.path)", error: error)
        }
    }

    func updateLiveStatus(
        _ status: LivePhotoStatus,
        for url: URL,
        folder: URL,
        recursively: Bool
    ) {
        do {
            let db = try openDatabase()
            guard let folderID = try folderID(
                in: db,
                folder: folder,
                recursively: recursively,
                createIfNeeded: false
            ) else {
                return
            }

            let sql = "UPDATE files SET live_status = ? WHERE folder_id = ? AND path = ?"
            var statement: OpaquePointer?
            try prepare(sql, in: db, statement: &statement)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, status.rawValue)
            sqlite3_bind_int64(statement, 2, folderID)
            bind(statement, 3, url.standardizedFileURL.path)
            try stepDone(statement, db: db)
        } catch {
            AppLogger.warning("更新 SQLite 实况状态失败：\(url.path)", error: error)
        }
    }

    func removeFolderIndex(folder: URL, recursively: Bool) {
        do {
            let db = try openDatabase()
            guard let folderID = try folderID(
                in: db,
                folder: folder,
                recursively: recursively,
                createIfNeeded: false
            ) else {
                return
            }
            try execute("DELETE FROM files WHERE folder_id = \(folderID)", in: db)
            try execute("DELETE FROM folders WHERE id = \(folderID)", in: db)
        } catch {
            AppLogger.warning("清理 SQLite 图库索引失败：\(folder.path)", error: error)
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK,
              let openedDatabase = db else {
            let message = sqliteMessage(db)
            if let db { sqlite3_close(db) }
            throw LibraryIndexError.sqlite(message)
        }

        database = openedDatabase
        sqlite3_busy_timeout(openedDatabase, 5_000)
        try execute("PRAGMA journal_mode = WAL", in: openedDatabase)
        try execute("PRAGMA synchronous = NORMAL", in: openedDatabase)
        try execute("PRAGMA foreign_keys = ON", in: openedDatabase)
        try migrateIfNeeded(in: openedDatabase)
        return openedDatabase
    }

    private func migrateIfNeeded(in db: OpaquePointer) throws {
        try execute("PRAGMA user_version = \(schemaVersion)", in: db)
        try execute("""
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            recursively INTEGER NOT NULL,
            last_scanned_at REAL,
            UNIQUE(path, recursively)
        )
        """, in: db)

        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_id INTEGER NOT NULL,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            media_kind TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            companion_path TEXT,
            companion_file_size INTEGER,
            companion_modified_at REAL,
            cache_key TEXT NOT NULL,
            make TEXT,
            model TEXT,
            software TEXT,
            captured_at TEXT,
            captured_at_ts REAL,
            pixel_width INTEGER,
            pixel_height INTEGER,
            latitude REAL,
            longitude REAL,
            live_status TEXT,
            search_text TEXT,
            metadata_indexed_at REAL,
            last_seen_scan_id TEXT NOT NULL,
            FOREIGN KEY(folder_id) REFERENCES folders(id) ON DELETE CASCADE,
            UNIQUE(folder_id, path)
        )
        """, in: db)

        try execute("CREATE INDEX IF NOT EXISTS idx_files_folder_modified ON files(folder_id, modified_at DESC)", in: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_files_folder_relative ON files(folder_id, relative_path COLLATE NOCASE)", in: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_files_folder_media ON files(folder_id, media_kind)", in: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_files_folder_cache_key ON files(folder_id, cache_key)", in: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_files_search_text ON files(folder_id, search_text COLLATE NOCASE)", in: db)
    }

    private func folderID(
        in db: OpaquePointer,
        folder: URL,
        recursively: Bool,
        createIfNeeded: Bool
    ) throws -> Int64? {
        let path = folder.standardizedFileURL.path
        if createIfNeeded {
            let insertSQL = """
            INSERT INTO folders(path, recursively, last_scanned_at)
            VALUES(?, ?, ?)
            ON CONFLICT(path, recursively) DO NOTHING
            """
            var insertStatement: OpaquePointer?
            try prepare(insertSQL, in: db, statement: &insertStatement)
            defer { sqlite3_finalize(insertStatement) }
            bind(insertStatement, 1, path)
            sqlite3_bind_int(insertStatement, 2, recursively ? 1 : 0)
            bind(insertStatement, 3, Date())
            try stepDone(insertStatement, db: db)
        }

        let selectSQL = "SELECT id FROM folders WHERE path = ? AND recursively = ? LIMIT 1"
        var selectStatement: OpaquePointer?
        try prepare(selectSQL, in: db, statement: &selectStatement)
        defer { sqlite3_finalize(selectStatement) }
        bind(selectStatement, 1, path)
        sqlite3_bind_int(selectStatement, 2, recursively ? 1 : 0)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(selectStatement, 0)
    }

    private func upsertDescriptors(
        _ descriptors: [PhotoFileDescriptor],
        folderID: Int64,
        root: URL,
        scanID: String,
        in db: OpaquePointer
    ) throws {
        let sql = """
        INSERT INTO files(
            folder_id, path, relative_path, media_kind, file_size, modified_at,
            companion_path, companion_file_size, companion_modified_at,
            cache_key, search_text, last_seen_scan_id
        )
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(folder_id, path) DO UPDATE SET
            relative_path = excluded.relative_path,
            media_kind = excluded.media_kind,
            file_size = excluded.file_size,
            modified_at = excluded.modified_at,
            companion_path = excluded.companion_path,
            companion_file_size = excluded.companion_file_size,
            companion_modified_at = excluded.companion_modified_at,
            cache_key = excluded.cache_key,
            search_text = CASE
                WHEN files.cache_key = excluded.cache_key THEN files.search_text
                ELSE excluded.search_text
            END,
            make = CASE WHEN files.cache_key = excluded.cache_key THEN files.make ELSE NULL END,
            model = CASE WHEN files.cache_key = excluded.cache_key THEN files.model ELSE NULL END,
            software = CASE WHEN files.cache_key = excluded.cache_key THEN files.software ELSE NULL END,
            captured_at = CASE WHEN files.cache_key = excluded.cache_key THEN files.captured_at ELSE NULL END,
            captured_at_ts = CASE WHEN files.cache_key = excluded.cache_key THEN files.captured_at_ts ELSE NULL END,
            pixel_width = CASE WHEN files.cache_key = excluded.cache_key THEN files.pixel_width ELSE NULL END,
            pixel_height = CASE WHEN files.cache_key = excluded.cache_key THEN files.pixel_height ELSE NULL END,
            latitude = CASE WHEN files.cache_key = excluded.cache_key THEN files.latitude ELSE NULL END,
            longitude = CASE WHEN files.cache_key = excluded.cache_key THEN files.longitude ELSE NULL END,
            metadata_indexed_at = CASE WHEN files.cache_key = excluded.cache_key THEN files.metadata_indexed_at ELSE NULL END,
            live_status = CASE WHEN files.cache_key = excluded.cache_key THEN files.live_status ELSE NULL END,
            last_seen_scan_id = excluded.last_seen_scan_id
        """

        var statement: OpaquePointer?
        try prepare(sql, in: db, statement: &statement)
        defer { sqlite3_finalize(statement) }

        for descriptor in descriptors {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            let path = descriptor.url.standardizedFileURL.path
            let relativePath = Self.relativePath(for: descriptor.url, root: root)
            let searchText = [
                descriptor.url.lastPathComponent,
                descriptor.url.deletingLastPathComponent().lastPathComponent,
                relativePath,
                descriptor.mediaKind == .video ? "视频 video mov mp4 m4v" : "照片 图片 photo image"
            ].joined(separator: " ")

            sqlite3_bind_int64(statement, 1, folderID)
            bind(statement, 2, path)
            bind(statement, 3, relativePath)
            bind(statement, 4, descriptor.mediaKind.rawValue)
            sqlite3_bind_int64(statement, 5, descriptor.fileSize)
            bind(statement, 6, descriptor.modifiedAt)
            bind(statement, 7, descriptor.companionVideoURL?.standardizedFileURL.path)
            bind(statement, 8, descriptor.companionVideoFileSize)
            bind(statement, 9, descriptor.companionVideoModifiedAt)
            bind(statement, 10, descriptor.cacheKey)
            bind(statement, 11, searchText)
            bind(statement, 12, scanID)
            try stepDone(statement, db: db)
        }
    }

    private func deleteRowsNotSeen(folderID: Int64, scanID: String, in db: OpaquePointer) throws {
        let sql = "DELETE FROM files WHERE folder_id = ? AND last_seen_scan_id != ?"
        var statement: OpaquePointer?
        try prepare(sql, in: db, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, folderID)
        bind(statement, 2, scanID)
        try stepDone(statement, db: db)
    }

    private func updateFolderScanTime(folderID: Int64, in db: OpaquePointer) throws {
        let sql = "UPDATE folders SET last_scanned_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, in: db, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, Date())
        sqlite3_bind_int64(statement, 2, folderID)
        try stepDone(statement, db: db)
    }

    private func execute(_ sql: String, in db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw LibraryIndexError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, in db: OpaquePointer, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LibraryIndexError.sqlite(sqliteMessage(db))
        }
    }

    private func stepDone(_ statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryIndexError.sqlite(sqliteMessage(db))
        }
    }

    private func sqliteMessage(_ db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Date?) {
        bind(statement, index, value?.timeIntervalSince1970)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func columnInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func columnDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        columnDouble(statement, index).map(Date.init(timeIntervalSince1970:))
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

private enum LibraryIndexError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "SQLite 索引错误：\(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
