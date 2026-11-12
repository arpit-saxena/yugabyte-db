#pragma once

/*
 * Odyssey.
 *
 * Scalable PostgreSQL connection pooler.
 */

int od_reset(od_server_t *);
int yb_send_reset_backend_default_query(od_server_t *server);
