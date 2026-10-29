#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * Cloud Suite — ограничение количества версий файлов (VERSIONS_MAX).
 *
 * Nextcloud хранит версии файлов в files_versions и умеет удалять их только
 * по времени (versions_retention_obligation). Бизнес-требование — не более
 * N версий на файл (по умолчанию 20, настраивается в .env: VERSIONS_MAX).
 *
 * Скрипт запускается внутри контейнера app от пользователя www-data:
 *
 *   docker compose exec -T -u www-data app php /opt/cloudsuite/custom/prune-versions.php
 *   docker compose exec -T -u www-data app php /opt/cloudsuite/custom/prune-versions.php --dry-run
 *
 * Планирование: make prune-versions (cron/systemd timer на хосте),
 * см. docs/06-versioning-and-retention.md.
 *
 * Алгоритм:
 *   1. По таблице oc_files_versions находим файлы, у которых версий > N.
 *   2. Для каждого файла через публичный API files_versions получаем список
 *      версий, сортируем по времени (новые первыми).
 *   3. Всё, что старше N-й версии, удаляется через IDeletableVersionBackend
 *      (корректно удаляет и объект в S3, и записи в БД).
 */

if (PHP_SAPI !== 'cli') {
	http_response_code(403);
	echo "This script can only be run from the command line.\n";
	exit(2);
}

$argvLocal = $_SERVER['argv'] ?? [];
$dryRun = false;
$maxOverride = null;
$quiet = false;

foreach (array_slice($argvLocal, 1) as $arg) {
	switch (true) {
		case $arg === '--dry-run':
			$dryRun = true;
			break;
		case $arg === '--quiet':
			$quiet = true;
			break;
		case $arg === '--help' || $arg === '-h':
			echo "Usage: php prune-versions.php [--dry-run] [--max=N] [--quiet]\n";
			echo "  --dry-run  ничего не удалять, только показать план\n";
			echo "  --max=N    переопределить VERSIONS_MAX для этого запуска\n";
			exit(0);
		case str_starts_with($arg, '--max='):
			$maxOverride = (int) substr($arg, 6);
			break;
		default:
			fwrite(STDERR, "Unknown argument: $arg (use --help)\n");
			exit(2);
	}
}

require_once '/var/www/html/lib/base.php';

@ini_set('memory_limit', '512M');
@set_time_limit(0);

try {
	\OC_App::loadApps(['files_versions']);
} catch (\Throwable $e) {
	fwrite(STDERR, 'FATAL: cannot load apps: ' . $e->getMessage() . "\n");
	exit(2);
}

$max = $maxOverride ?? (int) (getenv('VERSIONS_MAX') ?: 20);
if ($max < 1) {
	fwrite(STDERR, "FATAL: VERSIONS_MAX must be >= 1, got $max\n");
	exit(2);
}

/** @var \OCP\IDBConnection $db */
$db = \OC::$server->get(\OCP\IDBConnection::class);
/** @var \OCP\Files\IRootFolder $rootFolder */
$rootFolder = \OC::$server->get(\OCP\Files\IRootFolder::class);
/** @var \OCA\Files_Versions\Versions\VersionManager $versions */
$versions = \OC::$server->get(\OCA\Files_Versions\Versions\VersionManager::class);
/** @var \OCP\IUserSession $userSession */
$userSession = \OC::$server->get(\OCP\IUserSession::class);

$qb = $db->getQueryBuilder();
$qb->select('file_id')
	->selectAlias($qb->func()->count('file_id'), 'cnt')
	->from('files_versions')
	->groupBy('file_id');

$rows = $qb->executeQuery()->fetchAllAssociative();

$stats = [
	'max_versions' => $max,
	'dry_run' => $dryRun,
	'files_scanned' => count($rows),
	'files_pruned' => 0,
	'versions_deleted' => 0,
	'errors' => 0,
];

foreach ($rows as $row) {
	$count = (int) $row['cnt'];
	if ($count <= $max) {
		continue;
	}

	$fileId = (int) $row['file_id'];

	try {
		$node = $rootFolder->getFirstNodeById($fileId);
	} catch (\Throwable $e) {
		$stats['errors']++;
		fwrite(STDERR, "WARN: file id $fileId: " . $e->getMessage() . "\n");
		continue;
	}

	if ($node === null || !($node instanceof \OCP\Files\Node)) {
		continue;
	}

	$owner = method_exists($node, 'getOwner') ? $node->getOwner() : null;
	if ($owner === null) {
		$stats['errors']++;
		fwrite(STDERR, "WARN: file id $fileId: owner not found, skipped\n");
		continue;
	}

	// Удаление версий в files_versions работает через файловый API и требует
	// активного пользователя (иначе "No user logged in"). Входим в контекст
	// владельца файла, как это делает веб-интерфейс.
	\OC_Util::setupFS($owner->getUID());
	$userSession->setUser($owner);

	try {
		$fileVersions = $versions->getVersionsForFile($owner, $node);
	} catch (\Throwable $e) {
		$stats['errors']++;
		fwrite(STDERR, "WARN: file id $fileId: " . $e->getMessage() . "\n");
		\OC_Util::tearDownFS();
		continue;
	}

	if (count($fileVersions) <= $max) {
		\OC_Util::tearDownFS();
		continue;
	}

	// Новые версии первыми; всё начиная с (max+1)-й — удаляем.
	usort(
		$fileVersions,
		static fn ($a, $b): int => (int) $b->getTimestamp() <=> (int) $a->getTimestamp()
	);
	$excess = array_slice($fileVersions, $max);

	$deletedHere = 0;
	foreach ($excess as $version) {
		try {
			if (!$dryRun) {
				$versions->deleteVersion($version);
			}
			$deletedHere++;
		} catch (\Throwable $e) {
			$stats['errors']++;
			fwrite(STDERR, "WARN: file id $fileId: cannot delete version: " . $e->getMessage() . "\n");
		}
	}

	if ($deletedHere > 0) {
		$stats['files_pruned']++;
		$stats['versions_deleted'] += $deletedHere;
		if (!$quiet) {
			$path = $node->getPath();
			printf(
				"  %s %s: %d -> %d\n",
				$dryRun ? '[dry-run] would prune' : 'pruned',
				$path,
				count($fileVersions),
				count($fileVersions) - $deletedHere
			);
		}
	}

	\OC_Util::tearDownFS();
}

if (!$quiet) {
	echo json_encode($stats, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
}

exit($stats['errors'] > 0 ? 1 : 0);
