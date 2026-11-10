# Snowlit backup format 1

The `.snowlitbackup` file stores source scripts and import receipts, installations and public configuration, local books, historical book/chapter references, catalogs, reading positions and ordering, reader settings, public source state, and reference migration history. Chapter content is optional and retains the full semantic document, including descriptors not displayed by the text reader.

The file contains no SQLite database, executable SQL, filesystem paths, website data, Keychain contents, credential-read consent, cleanup tokens, or active operation permits. An import rebuilds a new App-owned schema. Checksums detect corruption; they do not authenticate an author or encrypt the contents. The scripts are data during preflight. Preflight does not inspect their executable contract or authorize them to run.

## Encoding

The file begins with eight ASCII bytes `SNOWBKP1`. Each frame then contains an unsigned 64-bit big-endian payload length, 64 lowercase ASCII hexadecimal checksum bytes, and that many bytes of UTF-8 JSON. The checksum is SHA-256 of the previous checksum's ASCII bytes followed by the current payload. The first previous checksum is 64 ASCII zeroes. A frame is limited to 64 MiB of encoded payload; archives are processed one row at a time without loading the entire library. An oversized record is rejected explicitly.

The first frame is a manifest: `formatVersion: 1`, `dataVersion: 1`, `summary`, and `rowCounts`. `summary` contains `createdAt` (Foundation's Codable date representation), `includesCache`, `sources`, `books`, and `cachedChapters`. `rowCounts` has one entry per fixed table in `BackupArchiveFormat.tables`. It also determines the exact frame count and table boundaries. Missing or trailing bytes are rejected.

Every following frame is an ordered array of typed values using Swift Codable's tagged enum representation: `null`, `integer`, `real`, `text`, or `blob` (base64). The fixed column order, required types, and nullable positions are defined in `BackupArchiveFormat.swift`. A chapter row has one additional blob with its canonical semantic content. There are no archive filenames to extract. The importer generates new UUID cache filenames after validating byte counts, revision and text digests, and chapter ownership.

`formatVersion` identifies the container framing; `dataVersion` identifies the persistent-data projection. Both are independent of the JavaScript protocol and internal SQLite schema versions. Unknown versions are rejected. Data version 1 reconstructs the schema-10 data model; subsequent database migrations must not silently reinterpret this projection.

## Consistency and preflight

Export runs under a database transaction. When cache is requested, a write transaction also prevents another connection from collecting referenced files. Read-only connections may export metadata but cannot export cache without a file lease. Export publishes a new file only after writing, synchronizing, and closing its temporary file. Existing destinations and live dataset directories are rejected.

Preflight creates an isolated directory, validates framing and checksums, inserts only the fixed columns with bound parameters, and verifies SQL constraints plus decoded domain relationships. It checks script digests, import receipts, source metadata, reference history, catalog ordering, saved positions, settings, public state, and optional chapter documents. It then closes and reopens the candidate through the production library opener. Failures remove the candidate or report a cleanup failure; the active descriptor is never changed.

Candidate reading sessions and website sessions are fresh. Reading positions, local identities, and ordering are retained. Runtime permits are absent and credential-read consent is cleared. This preflight API does not switch active datasets or clear old Keychain entries. Actual adoption must separately stop active owners, revalidate scripts through the source inspector, handle old credentials and website data, obtain required source permissions, and perform the approved recoverable dataset switch. A successful preflight is not completed restoration.
