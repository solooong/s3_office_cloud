<?php
/**
 * Cloud Suite — дополнительные системные настройки Nextcloud.
 *
 * Файл монтируется в /var/www/html/config/zz-10-cloudsuite.config.php и
 * загружается ПОСЛЕДНИМ (natsort), поэтому переопределяет значения,
 * которые задаёт образ Nextcloud и env-переменные.
 *
 * Здесь НЕ дублируются настройки, приходящие из окружения:
 *   - PostgreSQL, Redis, S3 (OBJECTSTORE_S3_*), SMTP, trusted_proxies,
 *     overwrite* — см. docker-compose.yml;
 *   - лимиты PHP — см. PHP_MEMORY_LIMIT / PHP_UPLOAD_LIMIT.
 *
 * @package cloudsuite
 */

$cloudsuiteLogDir = '/var/log/cloudsuite';
$cloudsuiteTz = getenv('TZ') ?: 'UTC';
$cloudsuiteLoglevelMap = [
	'debug' => 0,
	'info' => 1,
	'warn' => 2,
	'warning' => 2,
	'error' => 3,
	'fatal' => 4,
];
$cloudsuiteLogLevel = $cloudsuiteLoglevelMap[strtolower((string) getenv('LOG_LEVEL'))] ?? 2;

$CONFIG = [
	// --- Эксплуатация -------------------------------------------------------
	// Окно обслуживания: ночные задачи (версии, корзина) в 01:00 UTC
	'maintenance_window_start' => 1,
	'default_phone_region' => 'RU',
	'default_language' => 'ru',
	'default_locale' => 'ru_RU',
	'default_timezone' => $cloudsuiteTz,
	// Без демо-файлов у новых пользователей
	'skeletondirectory' => '',

	// --- Логи и аудит -------------------------------------------------------
	'log_type' => 'file',
	'logfile' => $cloudsuiteLogDir . '/nextcloud.log',
	'loglevel' => $cloudsuiteLogLevel,
	'logdatetimezone' => $cloudsuiteTz,
	'log_rotate_size' => 100 * 1024 * 1024,
	// Аудит действий пользователей (приложение admin_audit) — отдельный файл,
	// чтобы его можно было ротировать и отправлять в SIEM независимо.
	'log_type_audit' => 'file',
	'logfile_audit' => $cloudsuiteLogDir . '/audit.log',

	// --- Версии файлов и корзина -------------------------------------------
	// Количество версий (VERSIONS_MAX, по умолчанию 20) ограничивает
	// контейнер-скрипт config/nextcloud/custom/prune-versions.php (make prune-versions).
	// Здесь — время жизни версий и корзины как страховка.
	'versions_retention_obligation' => 'auto, ' . (int) (getenv('VERSIONS_RETENTION_DAYS') ?: 30),
	'trashbin_retention_obligation' => 'auto, ' . (int) (getenv('TRASH_RETENTION_DAYS') ?: 30),

	// --- Производительность и надёжность -----------------------------------
	'filelocking.enabled' => true,
	'filesystem_check_changes' => 0,
	'session_lifetime' => 86400,
	'session_keepalive' => true,
	'auth.bruteforce.protection.enabled' => true,
	// Проверка целостности кода включена (замедляет только админ-страницы)
	'integrity.check.disabled' => false,
	'check_for_working_wellknown_setup' => true,
	'knowledgebaseenabled' => false,
	'allow_user_to_change_display_name' => true,
	'allow_user_to_change_mail_address' => true,
	// Предпросмотры: ограничиваем память/CPU генерации
	'enable_previews' => true,
	'preview_max_x' => 2048,
	'preview_max_y' => 2048,
	'preview_max_filesize_image' => 50,
	'preview_max_memory' => 256,
	// Куда попадают файлы, которыми с пользователем поделились
	'share_folder' => '/Общие',
];
