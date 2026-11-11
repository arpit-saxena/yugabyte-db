#ifndef ODYSSEY_ROUTE_ID_H
#define ODYSSEY_ROUTE_ID_H

/*
 * Odyssey.
 *
 * Scalable PostgreSQL connection pooler.
 */

typedef struct od_route_id od_route_id_t;

struct od_route_id {

	/* (YB changes)
		char *user;
		int user_len;
		char *database;
		int database_len;
	*/

	bool physical_rep;
	bool logical_rep;

	int yb_stats_index;
	int yb_db_oid;
	int yb_user_oid;
};

static inline void od_route_id_init(od_route_id_t *id)
{
	/* YB: commenting out to avoid compiler errors
	id->user = NULL;
	id->user_len = 0;
	*/
	id->physical_rep = false;
	id->logical_rep = false;
	id->yb_db_oid = -1;
	id->yb_user_oid = -1;
}

#ifndef YB_SUPPORT_FOUND
/* invalid after moving to db/user oid pooling */
static inline void od_route_id_free(od_route_id_t *id)
{
	/* YB: commenting out to avoid compiler errors
	if (id->user)
		free(id->user);
	*/

}
#endif

static inline int od_route_id_copy(od_route_id_t *dest, od_route_id_t *id)
{
#ifndef YB_SUPPORT_FOUND
	dest->database = malloc(id->database_len);
	if (dest->database == NULL)
		return -1;
	memcpy(dest->database, id->database, id->database_len);
	dest->database_len = id->database_len;

	dest->user = malloc(id->user_len);
	if (dest->user == NULL) {
		free(dest->database);
		dest->database = NULL;
		return -1;
	}
	memcpy(dest->user, id->user, id->user_len);
	dest->user_len = id->user_len;

#else // YB_SUPPORT_FOUND
	dest->yb_db_oid = id->yb_db_oid;
	dest->yb_user_oid = id->yb_user_oid;
#endif // YB_SUPPORT_FOUND
	dest->physical_rep = id->physical_rep;
	dest->logical_rep = id->logical_rep;
	return 0;
}

static inline int od_route_id_compare(od_route_id_t *a, od_route_id_t *b)
{
		/*
		 * YB: physical_rep is not supported in YugabyteDB. So no comparison
		 * is required for it.
		 */
		if (a->yb_db_oid == b->yb_db_oid &&
		    a->yb_user_oid == b->yb_user_oid &&
		    a->logical_rep == b->logical_rep)
				return 1;
	return 0;
}

#endif /* ODYSSEY_ROUTE_ID_H */
