<?php
/**
 * Plugin Name: Praxis App Notifications
 * Description: Envoi de notifications sur application Android et iOS.
 * Version: 1.1.3
 * Author: PomgoWeb
 */

if (!defined('ABSPATH')) {
    exit;
}

define('RSAPP_PLUGIN_VERSION', '1.1.3');
define('RSAPP_CAPABILITY', 'edit_posts');
define('RSAPP_QUEUE_HOOK', 'rsapp_process_queue');
define('RSAPP_QUEUE_LOCK_KEY', 'rsapp_queue_lock');
define('RSAPP_IOS_BUNDLE_ID', 'com.praxismedia.ios');
define('RSAPP_ANDROID_CHANNEL_ID', 'rsapp_default_channel');

register_activation_hook(__FILE__, 'rsapp_activate');
register_deactivation_hook(__FILE__, 'rsapp_deactivate');

function rsapp_activate()
{
    rsapp_create_tables();
}

function rsapp_deactivate()
{
    wp_clear_scheduled_hook(RSAPP_QUEUE_HOOK);
    delete_transient(RSAPP_QUEUE_LOCK_KEY);
}

add_action('admin_init', 'rsapp_create_tables');
add_action(RSAPP_QUEUE_HOOK, 'rsapp_process_queue');

function rsapp_create_tables()
{
    global $wpdb;

    $charset_collate = $wpdb->get_charset_collate();
    $tokens_table = $wpdb->prefix . 'rsapp_tokens';
    $notifications_table = $wpdb->prefix . 'rsapp_notifications';
    $queue_table = $wpdb->prefix . 'rsapp_queue';

    require_once ABSPATH . 'wp-admin/includes/upgrade.php';

    $sql_tokens = "CREATE TABLE $tokens_table (
        id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
        token text NOT NULL,
        platform varchar(20) NOT NULL DEFAULT '',
        locale varchar(20) NOT NULL DEFAULT '',
        app_version varchar(20) NOT NULL DEFAULT '',
        created_at datetime NOT NULL,
        last_seen_at datetime NOT NULL,
        PRIMARY KEY  (id),
        UNIQUE KEY token (token(255))
    ) $charset_collate;";

    $sql_notifications = "CREATE TABLE $notifications_table (
        id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
        title varchar(200) NOT NULL,
        body text NOT NULL,
        url text NOT NULL,
        success_count int(11) NOT NULL DEFAULT 0,
        failure_count int(11) NOT NULL DEFAULT 0,
        last_error text NOT NULL,
        sent_at datetime NOT NULL,
        PRIMARY KEY  (id)
    ) $charset_collate;";

    $sql_queue = "CREATE TABLE $queue_table (
        id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
        title varchar(200) NOT NULL,
        body text NOT NULL,
        url text NOT NULL,
        status varchar(20) NOT NULL DEFAULT 'queued',
        success_count int(11) NOT NULL DEFAULT 0,
        failure_count int(11) NOT NULL DEFAULT 0,
        last_error text NOT NULL,
        last_token_id bigint(20) unsigned NOT NULL DEFAULT 0,
        total_tokens int(11) NOT NULL DEFAULT 0,
        created_at datetime NOT NULL,
        started_at datetime DEFAULT NULL,
        finished_at datetime DEFAULT NULL,
        updated_at datetime NOT NULL,
        PRIMARY KEY  (id),
        KEY status (status),
        KEY created_at (created_at)
    ) $charset_collate;";

    dbDelta($sql_tokens);
    dbDelta($sql_notifications);
    dbDelta($sql_queue);
}

add_action('admin_menu', 'rsapp_admin_menu');

function rsapp_admin_menu()
{
    add_menu_page(
        'Notifications',
        'Notifications',
        RSAPP_CAPABILITY,
        'rsapp-notifications',
        'rsapp_admin_page',
        'dashicons-megaphone',
        26
    );
}

function rsapp_admin_page()
{
    if (!current_user_can(RSAPP_CAPABILITY)) {
        return;
    }

    $notice = null;
    $errors = [];
    $test_result = null;

    if (isset($_POST['rsapp_send'])) {
        check_admin_referer('rsapp_send_notification');

        $title = sanitize_text_field(wp_unslash($_POST['rsapp_title'] ?? ''));
        $body = sanitize_textarea_field(wp_unslash($_POST['rsapp_body'] ?? ''));
        $url = esc_url_raw(wp_unslash($_POST['rsapp_url'] ?? ''));

        if ($title === '' || $body === '') {
            $errors[] = 'Titre et message sont obligatoires.';
        } else {
            $result = rsapp_send_notification($title, $body, $url);
            if (is_wp_error($result)) {
                $errors[] = $result->get_error_message();
            } else {
                $notice = sprintf(
                    "Notification en cours d'envoi en arriere-plan (cible: %d appareils).",
                    (int) ($result['queued_tokens'] ?? 0)
                );
            }
        }
    }

    if (isset($_POST['rsapp_test'])) {
        check_admin_referer('rsapp_test_notification');
        $test_result = rsapp_send_test_notification('');
        if (is_wp_error($test_result)) {
            $errors[] = $test_result->get_error_message();
        }
    }

    if (isset($_POST['rsapp_test_ios'])) {
        check_admin_referer('rsapp_test_notification');
        $test_result = rsapp_send_test_notification('ios');
        if (is_wp_error($test_result)) {
            $errors[] = $test_result->get_error_message();
        }
    }

    $history = rsapp_get_notification_history();
    $token_summary = rsapp_get_token_summary();

    echo '<div class="wrap">';
    echo '<h1>Notifications</h1>';

    if (!empty($errors)) {
        foreach ($errors as $error) {
            echo '<div class="notice notice-error"><p>' . esc_html($error) . '</p></div>';
        }
    }
    if ($notice) {
        echo '<div class="notice notice-success"><p>' . esc_html($notice) . '</p></div>';
    }
    if ($test_result && !is_wp_error($test_result)) {
        echo '<div class="notice notice-info"><p>' . esc_html($test_result) . '</p></div>';
    }

    echo '<form method="post">';
    wp_nonce_field('rsapp_send_notification');
    echo '<table class="form-table">';
    echo '<tr><th><label for="rsapp_title">Titre</label></th>';
    echo '<td><input type="text" id="rsapp_title" name="rsapp_title" class="regular-text" required></td></tr>';
    echo '<tr><th><label for="rsapp_body">Message</label></th>';
    echo '<td><textarea id="rsapp_body" name="rsapp_body" class="large-text" rows="4" required></textarea></td></tr>';
    echo '<tr><th><label for="rsapp_url">URL (optionnel)</label></th>';
    echo '<td><input type="url" id="rsapp_url" name="rsapp_url" class="regular-text" placeholder="https://praxismedia.fr/"></td></tr>';
    echo '</table>';
    echo '<p><button type="submit" name="rsapp_send" class="button button-primary">Envoyer</button></p>';
    echo '</form>';

    echo '<form method="post" style="margin-top:20px;">';
    wp_nonce_field('rsapp_test_notification');
    echo '<p><button type="submit" name="rsapp_test" class="button">Tester FCM (dernier token)</button></p>';
    echo '<p><button type="submit" name="rsapp_test_ios" class="button">Tester FCM (dernier token iOS)</button></p>';
    echo '</form>';

    echo '<h2>Tokens</h2>';
    echo '<p>Total: ' . esc_html((string) $token_summary['total']) . ' | iOS: ' . esc_html((string) $token_summary['ios']) . ' | Android: ' . esc_html((string) $token_summary['android']) . '</p>';
    if (empty($token_summary['latest'])) {
        echo '<p>Aucun token enregistre.</p>';
    } else {
        echo '<table class="widefat striped">';
        echo '<thead><tr><th>ID</th><th>Plateforme</th><th>Version</th><th>Derniere activite</th><th>Token hash</th></tr></thead><tbody>';
        foreach ($token_summary['latest'] as $token_row) {
            echo '<tr>';
            echo '<td>' . esc_html((string) $token_row['id']) . '</td>';
            echo '<td>' . esc_html((string) $token_row['platform']) . '</td>';
            echo '<td>' . esc_html((string) $token_row['app_version']) . '</td>';
            echo '<td>' . esc_html((string) $token_row['last_seen_at']) . '</td>';
            echo '<td>' . esc_html((string) $token_row['token_hash']) . '</td>';
            echo '</tr>';
        }
        echo '</tbody></table>';
    }

    echo '<h2>Historique</h2>';
    if (empty($history)) {
        echo '<p>Aucune notification envoyee.</p>';
    } else {
        echo '<table class="widefat striped">';
        echo '<thead><tr>';
        echo '<th>Date</th><th>Titre</th><th>URL</th><th style="display:none;">Succes</th><th style="display:none;">Echecs</th><th style="display:none;">Derniere erreur FCM</th>';
        echo '</tr></thead><tbody>';
        foreach ($history as $row) {
            echo '<tr>';
            echo '<td>' . esc_html($row['sent_at']) . '</td>';
            echo '<td>' . esc_html($row['title']) . '</td>';
            echo '<td>' . esc_html($row['url']) . '</td>';
            echo '<td style="display:none;">' . esc_html($row['success_count']) . '</td>';
            echo '<td style="display:none;">' . esc_html($row['failure_count']) . '</td>';
            echo '<td style="display:none;">' . esc_html(rsapp_excerpt($row['last_error'] ?? '')) . '</td>';
            echo '</tr>';
        }
        echo '</tbody></table>';
    }

    echo '</div>';
}

add_action('rest_api_init', 'rsapp_register_routes');

function rsapp_register_routes()
{
    register_rest_route('rsapp/v1', '/register-token', [
        'methods' => 'POST',
        'callback' => 'rsapp_register_token',
        'permission_callback' => 'rsapp_verify_request',
    ]);
}

function rsapp_verify_request(WP_REST_Request $request)
{
    $key = rsapp_get_secret_key();
    if (!$key) {
        return new WP_Error('rsapp_key_missing', 'Secret key not configured.', ['status' => 500]);
    }
    $provided = $request->get_header('x-rsapp-key');
    if (!$provided || !hash_equals($key, $provided)) {
        return new WP_Error('rsapp_invalid_key', 'Invalid key.', ['status' => 403]);
    }
    return true;
}

function rsapp_get_secret_key()
{
    if (defined('RSAPP_SECRET_KEY')) {
        return RSAPP_SECRET_KEY;
    }
    return get_option('rsapp_secret_key');
}

function rsapp_register_token(WP_REST_Request $request)
{
    global $wpdb;

    $data = $request->get_json_params();
    $token = rsapp_normalize_token($data['token'] ?? '');
    $platform = sanitize_text_field($data['platform'] ?? '');
    $locale = sanitize_text_field($data['locale'] ?? '');
    $app_version = sanitize_text_field($data['appVersion'] ?? '');

    if ($token === '') {
        return new WP_Error('rsapp_token_missing', 'Token missing.', ['status' => 400]);
    }

    $table = $wpdb->prefix . 'rsapp_tokens';
    $now = current_time('mysql', 1);

    $query = $wpdb->prepare(
        "INSERT INTO $table (token, platform, locale, app_version, created_at, last_seen_at)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE platform = VALUES(platform),
        locale = VALUES(locale),
        app_version = VALUES(app_version),
        last_seen_at = VALUES(last_seen_at)",
        $token,
        $platform,
        $locale,
        $app_version,
        $now,
        $now
    );

    $db_result = $wpdb->query($query);
    if ($db_result === false) {
        $db_error = $wpdb->last_error ? $wpdb->last_error : 'Unknown database error.';
        rsapp_debug_log('token-register-db-error', [
            'platform' => $platform,
            'app_version' => $app_version,
            'token_hash' => rsapp_short_token_hash($token),
            'db_error' => $db_error,
        ]);
        return new WP_Error('rsapp_token_db_error', 'Token database write failed: ' . $db_error, ['status' => 500]);
    }

    $token_id = (int) $wpdb->insert_id;
    if ($token_id <= 0) {
        $token_id = (int) $wpdb->get_var(
            $wpdb->prepare(
                "SELECT id FROM $table WHERE token = %s LIMIT 1",
                $token
            )
        );
    }

    if ($token_id <= 0) {
        $db_error = $wpdb->last_error ? $wpdb->last_error : 'Token row not found after database write.';
        rsapp_debug_log('token-register-db-missing-row', [
            'platform' => $platform,
            'app_version' => $app_version,
            'token_hash' => rsapp_short_token_hash($token),
            'db_result' => $db_result,
            'db_error' => $db_error,
        ]);
        return new WP_Error('rsapp_token_db_missing_row', 'Token database readback failed: ' . $db_error, ['status' => 500]);
    }

    rsapp_debug_log('token-registered', [
        'token_id' => $token_id,
        'platform' => $platform,
        'app_version' => $app_version,
        'token_hash' => rsapp_short_token_hash($token),
        'db_result' => $db_result,
    ]);

    return [
        'status' => 'ok',
        'token_id' => $token_id,
        'platform' => $platform,
        'token_hash' => rsapp_short_token_hash($token),
    ];
}

function rsapp_send_notification($title, $body, $url)
{
    global $wpdb;
    $tokens_table = $wpdb->prefix . 'rsapp_tokens';
    $queue_table = $wpdb->prefix . 'rsapp_queue';
    $service_account = rsapp_get_service_account();
    if (is_wp_error($service_account)) {
        return $service_account;
    }
    $total_tokens = (int) $wpdb->get_var("SELECT COUNT(1) FROM $tokens_table");
    if ($total_tokens <= 0) {
        return new WP_Error('rsapp_no_tokens', 'Aucun token enregistre.');
    }

    $now = current_time('mysql', 1);
    $inserted = $wpdb->insert(
        $queue_table,
        [
            'title' => $title,
            'body' => $body,
            'url' => $url ?: '',
            'status' => 'queued',
            'success_count' => 0,
            'failure_count' => 0,
            'last_error' => '',
            'last_token_id' => 0,
            'total_tokens' => $total_tokens,
            'created_at' => $now,
            'updated_at' => $now,
        ],
        ['%s', '%s', '%s', '%s', '%d', '%d', '%s', '%d', '%d', '%s', '%s']
    );
    if (!$inserted) {
        return new WP_Error('rsapp_queue_insert_failed', 'Impossible de planifier la notification.');
    }
    rsapp_schedule_queue_process(1);
    if (function_exists('spawn_cron')) {
        spawn_cron(time());
    }
    return [
        'queue_id' => (int) $wpdb->insert_id,
        'queued_tokens' => $total_tokens,
    ];
}

function rsapp_schedule_queue_process($delay_seconds = 1)
{
    $delay = max(1, (int) $delay_seconds);
    if (!wp_next_scheduled(RSAPP_QUEUE_HOOK)) {
        wp_schedule_single_event(time() + $delay, RSAPP_QUEUE_HOOK);
    }
}

function rsapp_get_queue_batch_size()
{
    $batch_size = (int) apply_filters('rsapp_queue_batch_size', 120);
    if ($batch_size < 25) {
        $batch_size = 25;
    }
    if ($batch_size > 500) {
        $batch_size = 500;
    }
    return $batch_size;
}

function rsapp_process_queue()
{
    if (get_transient(RSAPP_QUEUE_LOCK_KEY)) {
        return;
    }
    set_transient(RSAPP_QUEUE_LOCK_KEY, '1', 55);

    try {
        global $wpdb;
        $queue_table = $wpdb->prefix . 'rsapp_queue';
        $tokens_table = $wpdb->prefix . 'rsapp_tokens';
        $queue = $wpdb->get_row(
            "SELECT * FROM $queue_table WHERE status IN ('queued','processing') ORDER BY id ASC LIMIT 1",
            ARRAY_A
        );

        if (empty($queue)) {
            return;
        }

        $queue_id = (int) $queue['id'];
        $now = current_time('mysql', 1);
        if ($queue['status'] === 'queued') {
            $wpdb->update(
                $queue_table,
                [
                    'status' => 'processing',
                    'started_at' => $now,
                    'updated_at' => $now,
                ],
                ['id' => $queue_id],
                ['%s', '%s', '%s'],
                ['%d']
            );
            $queue['status'] = 'processing';
            $queue['started_at'] = $now;
        }

        $service_account = rsapp_get_service_account();
        if (is_wp_error($service_account)) {
            rsapp_fail_queue($queue, $service_account->get_error_message());
            rsapp_schedule_queue_process(5);
            return;
        }
        $access_token = rsapp_get_access_token($service_account);
        if (is_wp_error($access_token)) {
            rsapp_fail_queue($queue, $access_token->get_error_message());
            rsapp_schedule_queue_process(5);
            return;
        }
        $project_id = $service_account['project_id'] ?? null;
        if (!$project_id) {
            rsapp_fail_queue($queue, 'Project ID manquant dans le service account.');
            rsapp_schedule_queue_process(5);
            return;
        }

        $batch_size = rsapp_get_queue_batch_size();
        $last_token_id = (int) $queue['last_token_id'];
        $tokens = $wpdb->get_results(
            $wpdb->prepare(
                "SELECT id, token, platform, app_version, last_seen_at FROM $tokens_table WHERE id > %d ORDER BY id ASC LIMIT %d",
                $last_token_id,
                $batch_size
            ),
            ARRAY_A
        );

        if (empty($tokens)) {
            rsapp_complete_queue($queue);
            rsapp_schedule_queue_process(1);
            return;
        }

        $success = (int) $queue['success_count'];
        $failure = (int) $queue['failure_count'];
        $last_error = (string) ($queue['last_error'] ?? '');
        $invalid_ids = [];
        $last_processed_id = $last_token_id;

        foreach ($tokens as $row) {
            $last_processed_id = (int) $row['id'];
            $result = rsapp_send_to_token(
                $project_id,
                $access_token,
                $row['token'],
                $queue['title'],
                $queue['body'],
                $queue['url'],
                [
                    'token_id' => (int) $row['id'],
                    'platform' => (string) ($row['platform'] ?? ''),
                    'app_version' => (string) ($row['app_version'] ?? ''),
                    'last_seen_at' => (string) ($row['last_seen_at'] ?? ''),
                ]
            );

            if (!empty($result['ok'])) {
                $success++;
                continue;
            }

            $failure++;
            $last_error = $result['error'] ?? $result['body'] ?? '';
            if (!empty($result['invalid'])) {
                $invalid_ids[] = (int) $row['id'];
                rsapp_debug_log('fcm-invalid-token-removed', ['token_id' => (int) $row['id']]);
            }
        }

        if (!empty($invalid_ids)) {
            $ids = implode(',', array_map('intval', $invalid_ids));
            $wpdb->query("DELETE FROM $tokens_table WHERE id IN ($ids)");
        }

        $wpdb->update(
            $queue_table,
            [
                'success_count' => $success,
                'failure_count' => $failure,
                'last_error' => rsapp_excerpt($last_error, 500),
                'last_token_id' => $last_processed_id,
                'updated_at' => current_time('mysql', 1),
            ],
            ['id' => $queue_id],
            ['%d', '%d', '%s', '%d', '%s'],
            ['%d']
        );

        if (count($tokens) < $batch_size) {
            $queue['success_count'] = $success;
            $queue['failure_count'] = $failure;
            $queue['last_error'] = $last_error;
            rsapp_complete_queue($queue);
            rsapp_schedule_queue_process(1);
            return;
        }

        rsapp_schedule_queue_process(1);
    } finally {
        delete_transient(RSAPP_QUEUE_LOCK_KEY);
    }
}

function rsapp_fail_queue(array $queue, $error_message)
{
    global $wpdb;
    $queue_table = $wpdb->prefix . 'rsapp_queue';
    $queue_id = (int) $queue['id'];
    $now = current_time('mysql', 1);
    $failure = max((int) ($queue['failure_count'] ?? 0), (int) ($queue['total_tokens'] ?? 0));
    $error_message = (string) $error_message;

    $wpdb->update(
        $queue_table,
        [
            'status' => 'failed',
            'failure_count' => $failure,
            'last_error' => rsapp_excerpt($error_message, 500),
            'finished_at' => $now,
            'updated_at' => $now,
        ],
        ['id' => $queue_id],
        ['%s', '%d', '%s', '%s', '%s'],
        ['%d']
    );

    rsapp_log_notification(
        $queue['title'],
        $queue['body'],
        $queue['url'],
        (int) ($queue['success_count'] ?? 0),
        $failure,
        $error_message
    );
    rsapp_debug_log('queue-error', ['queue_id' => $queue_id, 'error' => $error_message]);
}

function rsapp_complete_queue(array $queue)
{
    global $wpdb;
    $queue_table = $wpdb->prefix . 'rsapp_queue';
    $queue_id = (int) $queue['id'];
    $now = current_time('mysql', 1);

    $wpdb->update(
        $queue_table,
        [
            'status' => 'done',
            'finished_at' => $now,
            'updated_at' => $now,
        ],
        ['id' => $queue_id],
        ['%s', '%s', '%s'],
        ['%d']
    );

    rsapp_log_notification(
        $queue['title'],
        $queue['body'],
        $queue['url'],
        (int) ($queue['success_count'] ?? 0),
        (int) ($queue['failure_count'] ?? 0),
        (string) ($queue['last_error'] ?? '')
    );
}

function rsapp_send_to_token($project_id, $access_token, $token, $title, $body, $url, array $context = [])
{
    $token = rsapp_normalize_token($token);
    $endpoint = sprintf('https://fcm.googleapis.com/v1/projects/%s/messages:send', $project_id);
    $log_context = array_merge($context, [
        'token_hash' => rsapp_short_token_hash($token),
    ]);

    $message = [
        'token' => $token,
        'notification' => [
            'title' => $title,
            'body' => $body,
        ],
        'android' => [
            'notification' => [
                'channel_id' => RSAPP_ANDROID_CHANNEL_ID,
                'sound' => 'default',
                'title' => $title,
                'body' => $body,
            ],
        ],
        'apns' => [
            'headers' => [
                'apns-push-type' => 'alert',
                'apns-priority' => '10',
                'apns-topic' => RSAPP_IOS_BUNDLE_ID,
            ],
            'payload' => [
                'aps' => [
                    'sound' => 'default',
                    'alert' => [
                        'title' => $title,
                        'body' => $body,
                    ],
                ],
            ],
        ],
    ];

    if (!empty($url)) {
        $message['data'] = [
            'title' => (string) $title,
            'body' => (string) $body,
            'url' => (string) $url,
        ];
    } else {
        $message['data'] = [
            'title' => (string) $title,
            'body' => (string) $body,
        ];
    }

    $payload = [
        'message' => $message,
    ];

    $response = wp_remote_post($endpoint, [
        'headers' => [
            'Authorization' => 'Bearer ' . $access_token,
            'Content-Type' => 'application/json; charset=utf-8',
        ],
        'body' => wp_json_encode($payload),
        'timeout' => 15,
    ]);

    if (is_wp_error($response)) {
        rsapp_debug_log('fcm-error', [
            'endpoint' => $endpoint,
            'error' => $response->get_error_message(),
        ] + $log_context);
        return [
            'ok' => false,
            'code' => 0,
            'body' => '',
            'invalid' => false,
            'error' => $response->get_error_message(),
        ];
    }

    $code = wp_remote_retrieve_response_code($response);
    $body = wp_remote_retrieve_body($response);

    rsapp_debug_log('fcm-response', [
        'code' => $code,
        'body' => rsapp_excerpt($body, 500),
    ] + $log_context);

    if ($code < 200 || $code >= 300) {
        rsapp_debug_log('fcm-error', [
            'endpoint' => $endpoint,
            'code' => $code,
            'body' => $body,
        ] + $log_context);
    }

    if (rsapp_is_invalid_token($body)) {
        return [
            'ok' => false,
            'code' => $code,
            'body' => $body,
            'invalid' => true,
        ];
    }

    if ($code >= 200 && $code < 300) {
        return [
            'ok' => true,
            'code' => $code,
            'body' => $body,
            'invalid' => false,
        ];
    }

    return [
        'ok' => false,
        'code' => $code,
        'body' => $body,
        'invalid' => false,
    ];
}

function rsapp_is_invalid_token($body)
{
    $data = json_decode($body, true);
    if (!is_array($data) || empty($data['error']['details'])) {
        return false;
    }

    foreach ($data['error']['details'] as $detail) {
        if (!isset($detail['@type'], $detail['errorCode'])) {
            continue;
        }
        if ($detail['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError' &&
            $detail['errorCode'] === 'UNREGISTERED') {
            return true;
        }
    }
    return false;
}

function rsapp_get_service_account()
{
    $path = null;
    if (defined('RSAPP_FCM_SERVICE_ACCOUNT')) {
        $path = RSAPP_FCM_SERVICE_ACCOUNT;
    } else {
        $path = get_option('rsapp_fcm_service_account');
    }

    if (!$path || !file_exists($path)) {
        return new WP_Error('rsapp_sa_missing', 'Service account JSON introuvable.');
    }

    $raw = file_get_contents($path);
    $json = json_decode($raw, true);
    if (!is_array($json)) {
        return new WP_Error('rsapp_sa_invalid', 'Service account JSON invalide.');
    }

    return $json;
}

function rsapp_get_access_token($service_account)
{
    $token_uri = $service_account['token_uri'] ?? null;
    $client_email = $service_account['client_email'] ?? null;
    $private_key = $service_account['private_key'] ?? null;

    if (!$token_uri || !$client_email || !$private_key) {
        return new WP_Error('rsapp_sa_fields', 'Champs manquants dans le service account.');
    }

    $now = time();
    $payload = [
        'iss' => $client_email,
        'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
        'aud' => $token_uri,
        'iat' => $now,
        'exp' => $now + 3600,
    ];

    $jwt = rsapp_base64url(json_encode(['alg' => 'RS256', 'typ' => 'JWT'])) . '.' .
        rsapp_base64url(json_encode($payload));

    $signature = '';
    $signed = openssl_sign($jwt, $signature, $private_key, 'sha256WithRSAEncryption');
    if (!$signed) {
        return new WP_Error('rsapp_jwt_sign', 'Signature JWT impossible.');
    }

    $jwt .= '.' . rsapp_base64url($signature);

    $response = wp_remote_post($token_uri, [
        'body' => [
            'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion' => $jwt,
        ],
        'timeout' => 15,
    ]);

    if (is_wp_error($response)) {
        return $response;
    }

    $code = wp_remote_retrieve_response_code($response);
    $body = wp_remote_retrieve_body($response);
    $data = json_decode($body, true);

    if ($code !== 200 || empty($data['access_token'])) {
        return new WP_Error('rsapp_oauth_failed', 'OAuth failed: ' . $body);
    }

    return $data['access_token'];
}

function rsapp_base64url($data)
{
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function rsapp_get_notification_history()
{
    global $wpdb;
    $table = $wpdb->prefix . 'rsapp_notifications';
    return $wpdb->get_results(
        "SELECT title, body, url, success_count, failure_count, last_error, sent_at
        FROM $table ORDER BY sent_at DESC LIMIT 10",
        ARRAY_A
    );
}

function rsapp_get_token_summary()
{
    global $wpdb;
    $table = $wpdb->prefix . 'rsapp_tokens';
    $total = (int) $wpdb->get_var("SELECT COUNT(1) FROM $table");
    $ios = (int) $wpdb->get_var($wpdb->prepare("SELECT COUNT(1) FROM $table WHERE platform = %s", 'ios'));
    $android = (int) $wpdb->get_var($wpdb->prepare("SELECT COUNT(1) FROM $table WHERE platform = %s", 'android'));
    $latest = $wpdb->get_results(
        "SELECT id, token, platform, app_version, last_seen_at FROM $table ORDER BY last_seen_at DESC LIMIT 10",
        ARRAY_A
    );

    foreach ($latest as &$row) {
        $row['token_hash'] = rsapp_short_token_hash((string) ($row['token'] ?? ''));
        unset($row['token']);
    }
    unset($row);

    return [
        'total' => $total,
        'ios' => $ios,
        'android' => $android,
        'latest' => $latest,
    ];
}

function rsapp_log_notification($title, $body, $url, $success, $failure, $last_error)
{
    global $wpdb;
    $table = $wpdb->prefix . 'rsapp_notifications';
    $wpdb->insert(
        $table,
        [
            'title' => $title,
            'body' => $body,
            'url' => $url ?: '',
            'success_count' => (int) $success,
            'failure_count' => (int) $failure,
            'last_error' => rsapp_excerpt($last_error, 500),
            'sent_at' => current_time('mysql', 1),
        ],
        ['%s', '%s', '%s', '%d', '%d', '%s', '%s']
    );
}

function rsapp_send_test_notification($platform = '')
{
    global $wpdb;
    $tokens_table = $wpdb->prefix . 'rsapp_tokens';
    $platform = sanitize_text_field((string) $platform);
    if ($platform !== '') {
        $row = $wpdb->get_row(
            $wpdb->prepare(
                "SELECT id, token, platform, app_version, last_seen_at FROM $tokens_table WHERE platform = %s ORDER BY last_seen_at DESC LIMIT 1",
                $platform
            ),
            ARRAY_A
        );
    } else {
        $row = $wpdb->get_row(
            "SELECT id, token, platform, app_version, last_seen_at FROM $tokens_table ORDER BY last_seen_at DESC LIMIT 1",
            ARRAY_A
        );
    }

    if (empty($row['token'])) {
        $message = $platform === '' ? 'Aucun token enregistre pour le test.' : sprintf('Aucun token %s enregistre pour le test.', $platform);
        return new WP_Error('rsapp_no_tokens', $message);
    }

    $service_account = rsapp_get_service_account();
    if (is_wp_error($service_account)) {
        return $service_account;
    }

    $access_token = rsapp_get_access_token($service_account);
    if (is_wp_error($access_token)) {
        return $access_token;
    }

    $project_id = $service_account['project_id'] ?? null;
    if (!$project_id) {
        return new WP_Error('rsapp_project_id', 'Project ID manquant dans le service account.');
    }

    $result = rsapp_send_to_token(
        $project_id,
        $access_token,
        $row['token'],
        'Test Praxis',
        'Notification de test.',
        '',
        [
            'token_id' => (int) ($row['id'] ?? 0),
            'platform' => (string) ($row['platform'] ?? ''),
            'app_version' => (string) ($row['app_version'] ?? ''),
            'last_seen_at' => (string) ($row['last_seen_at'] ?? ''),
        ]
    );

    if (!empty($result['invalid'])) {
        $wpdb->delete($tokens_table, ['token' => $row['token']], ['%s']);
    }

    return sprintf(
        'Test FCM: token_id=%s platform=%s app_version=%s last_seen=%s token_hash=%s code=%s body=%s',
        (string) ($row['id'] ?? ''),
        (string) ($row['platform'] ?? ''),
        (string) ($row['app_version'] ?? ''),
        (string) ($row['last_seen_at'] ?? ''),
        rsapp_short_token_hash((string) ($row['token'] ?? '')),
        (string) ($result['code'] ?? '0'),
        rsapp_excerpt($result['body'] ?? $result['error'] ?? '', 400)
    );
}

function rsapp_is_debug()
{
    if (defined('RSAPP_DEBUG')) {
        return rsapp_to_bool(RSAPP_DEBUG);
    }
    return rsapp_to_bool(get_option('rsapp_debug'));
}

function rsapp_to_bool($value)
{
    if (is_bool($value)) {
        return $value;
    }
    $value = strtolower(trim((string) $value));
    return in_array($value, ['1', 'true', 'yes', 'on'], true);
}

function rsapp_debug_log($message, array $context = [])
{
    if (!rsapp_is_debug()) {
        return;
    }
    $payload = '';
    if (!empty($context)) {
        $payload = ' ' . wp_json_encode($context);
    }
    error_log('[RSAPP] ' . $message . $payload);
}

function rsapp_normalize_token($token)
{
    $token = sanitize_text_field($token);
    $token = trim($token);
    return preg_replace('/\s+/', '', $token);
}

function rsapp_short_token_hash($token)
{
    $token = rsapp_normalize_token($token);
    if ($token === '') {
        return '';
    }
    return substr(hash('sha256', $token), 0, 12);
}

function rsapp_excerpt($value, $max = 200)
{
    $value = (string) $value;
    if (strlen($value) <= $max) {
        return $value;
    }
    return substr($value, 0, $max) . '...';
}
