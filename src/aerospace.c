#include <errno.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "aerospace.h"
#include "yyjson.h"

#define READ_BUFFER_SIZE 8192
#define SOCKET_CONNECT_MAX_ATTEMPTS 30
#define SOCKET_CONNECT_RETRY_USEC 1000000

// AeroSpace's Unix-socket wire protocol (Sources/Common/util/NWConnectionEx.swift,
// Sources/Common/model/clientServer.swift upstream): on connect, both sides
// exchange a raw 4-byte little-endian version handshake; every request/response
// after that is a 4-byte little-endian length prefix followed by that many bytes
// of JSON. There is no newline delimiter and no incremental JSON scanning.
#define SOCKET_PROTOCOL_VERSION 1u

static const char* ERROR_SOCKET_CREATE = "Failed to create Unix domain socket";
static const char* ERROR_SOCKET_RECEIVE = "Failed to receive data from socket";
static const char* ERROR_SOCKET_CLOSE = "Failed to close socket connection";
static const char* ERROR_JSON_PRINT = "Failed to print JSON to string";
static const char* WARN_CLI_FALLBACK = "Warning: Failed to connect to socket at %s: %s (errno %d). Falling back to CLI.";

struct aerospace {
	int fd;
	char* socket_path;
	bool use_cli_fallback;
	char read_buf[READ_BUFFER_SIZE];
};

// Serializes socket I/O on the shared client connection. maybe_dispatch_switch()
// and fire_single_swipe() both dispatch switch_workspace() onto a workspace
// queue, so back-to-back swipes can otherwise race on the same fd/read_buf and
// corrupt the JSON protocol, permanently breaking the connection.
static pthread_mutex_t g_socket_mutex = PTHREAD_MUTEX_INITIALIZER;

static void fatal_error(const char* fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "Fatal Error: ");
	vfprintf(stderr, fmt, args);
	if (errno != 0)
		fprintf(stderr, ": %s (errno %d)", strerror(errno), errno);
	fprintf(stderr, "\n");
	va_end(args);
	exit(EXIT_FAILURE);
}

static char* get_default_socket_path(void)
{
	uid_t uid = getuid();
	struct passwd* pw = getpwuid(uid);

	if (uid == 0) {
		const char* sudo_user = getenv("SUDO_USER");
		if (sudo_user) {
			struct passwd* pw_temp = getpwnam(sudo_user);
			if (pw_temp)
				pw = pw_temp;
		} else {
			const char* user_env = getenv("USER");
			if (user_env && strcmp(user_env, "root") != 0) {
				struct passwd* pw_temp = getpwnam(user_env);
				if (pw_temp)
					pw = pw_temp;
			}
		}
	}

	if (!pw)
		fatal_error("Unable to determine user information for default socket path");

	const char* username = pw->pw_name;
	size_t len = snprintf(NULL, 0, "/tmp/bobko.aerospace-%s.sock", username);
	char* path = malloc(len + 1);
	snprintf(path, len + 1, "/tmp/bobko.aerospace-%s.sock", username);
	return path;
}

static bool write_exact(int fd, const uint8_t* buf, size_t n)
{
	size_t sent = 0;
	while (sent < n) {
		ssize_t w = write(fd, buf + sent, n - sent);
		if (w <= 0)
			return false;
		sent += (size_t)w;
	}
	return true;
}

static bool read_exact(int fd, uint8_t* buf, size_t n)
{
	size_t got = 0;
	while (got < n) {
		ssize_t r = read(fd, buf + got, n - got);
		if (r <= 0)
			return false;
		got += (size_t)r;
	}
	return true;
}

static void put_le_u32(uint8_t* out, uint32_t v)
{
	out[0] = (uint8_t)(v);
	out[1] = (uint8_t)(v >> 8);
	out[2] = (uint8_t)(v >> 16);
	out[3] = (uint8_t)(v >> 24);
}

static uint32_t get_le_u32(const uint8_t* in)
{
	return (uint32_t)in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}

// AeroSpace closes the connection immediately if this handshake doesn't
// happen first, or if the versions don't match.
static bool aerospace_handshake(int fd)
{
	uint8_t buf[4];
	put_le_u32(buf, SOCKET_PROTOCOL_VERSION);
	if (!write_exact(fd, buf, 4))
		return false;
	if (!read_exact(fd, buf, 4))
		return false;
	return get_le_u32(buf) == SOCKET_PROTOCOL_VERSION;
}

// Re-dials client->socket_path after the connection has broken (e.g. a
// racing writer corrupted the protocol and AeroSpace closed the socket).
// Single attempt, no backoff: by this point AeroSpace is already up, so a
// long retry loop like aerospace_new()'s startup one isn't needed here.
static bool aerospace_reconnect(aerospace* client)
{
	if (client->fd >= 0) {
		close(client->fd);
		client->fd = -1;
	}

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, client->socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return false;

	if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0 || !aerospace_handshake(fd)) {
		close(fd);
		return false;
	}

	client->fd = fd;
	return true;
}

static char* execute_cli_command(const char* command_string)
{
	FILE* pipe = popen(command_string, "r");
	if (!pipe) {
		fatal_error("popen() failed for command '%s'", command_string);
	}

	char* output = malloc(READ_BUFFER_SIZE + 1);
	if (!output) {
		pclose(pipe);
		fatal_error("Failed to allocate buffer for CLI output");
	}

	size_t nread = fread(output, 1, READ_BUFFER_SIZE, pipe);
	output[nread] = '\0';

	int status = pclose(pipe);
	if (status != 0) {
		if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
			fprintf(stderr, "Warning: CLI command failed with exit code %d: %s\n", WEXITSTATUS(status), command_string);
		} else if (status == -1) {
			fprintf(stderr, "Warning: pclose failed: %s\n", strerror(errno));
		}
	}

	if (nread > 0 && output[nread - 1] == '\n') {
		output[nread - 1] = '\0';
	}

	return output;
}

static char* execute_aerospace_command(aerospace* client, const char** args, int arg_count, const char* stdin_payload, const char* expected_output_field)
{
	if (!client || !args || arg_count == 0) {
		errno = EINVAL;
		fprintf(stderr, "execute_aerospace_command: Invalid arguments\n");
		return NULL;
	}

	if (client->use_cli_fallback) {
		// AeroSpace v0.20.0+ requires `workspace next/prev` to receive an
		// explicit --stdin or --no-stdin flag; without one the CLI errors out.
		// The socket protocol carries stdin in its JSON envelope, so we only
		// need this for the CLI fallback path.
		const char* stdin_flag = NULL;
		if (strcmp(args[0], "workspace") == 0) {
			stdin_flag = (stdin_payload && strlen(stdin_payload) > 0) ? "--stdin" : "--no-stdin";
		}

		size_t total_len = strlen("aerospace");
		for (int i = 0; i < arg_count; i++) {
			total_len += 1 + strlen(args[i]);
		}
		if (stdin_flag) {
			total_len += 1 + strlen(stdin_flag);
		}

		char* cli_command_base = malloc(total_len + 1);
		if (!cli_command_base) {
			fatal_error("Failed to allocate memory for CLI command");
		}

		char* p = cli_command_base;
		p += sprintf(p, "aerospace");
		for (int i = 0; i < arg_count; i++) {
			p += sprintf(p, " %s", args[i]);
		}
		if (stdin_flag) {
			p += sprintf(p, " %s", stdin_flag);
		}

		char* final_command;
		if (stdin_payload && strlen(stdin_payload) > 0) {
			const char* format = "echo '%s' | %s";
			size_t len = snprintf(NULL, 0, format, stdin_payload, cli_command_base);
			final_command = malloc(len + 1);
			snprintf(final_command, len + 1, format, stdin_payload, cli_command_base);
			free(cli_command_base);
		} else {
			final_command = cli_command_base;
		}

		char* result = execute_cli_command(final_command);
		free(final_command);
		return result;
	}

	yyjson_mut_doc* doc = yyjson_mut_doc_new(NULL);
	yyjson_mut_val* root = yyjson_mut_obj(doc);
	yyjson_mut_doc_set_root(doc, root);
	yyjson_mut_obj_add_str(doc, root, "command", args[0]);
	yyjson_mut_obj_add_str(doc, root, "stdin", stdin_payload ? stdin_payload : "");
	yyjson_mut_val* args_array = yyjson_mut_arr(doc);
	for (int i = 0; i < arg_count; i++) {
		yyjson_mut_arr_add_str(doc, args_array, args[i]);
	}
	yyjson_mut_obj_add_val(doc, root, "args", args_array);
	size_t len;
	const char* json_str = yyjson_mut_write(doc, 0, &len);
	yyjson_mut_doc_free(doc);
	if (!json_str) {
		fatal_error(ERROR_JSON_PRINT);
	}

	pthread_mutex_lock(&g_socket_mutex);

	char* result = NULL;
	for (int attempt = 0; attempt < 2; attempt++) {
		uint8_t len_prefix[4];
		put_le_u32(len_prefix, (uint32_t)len);

		bool sent = write_exact(client->fd, len_prefix, 4) && write_exact(client->fd, (const uint8_t*)json_str, len);
		if (!sent) {
			fprintf(stderr, "Failed to send request to socket\n");
			if (attempt == 0 && aerospace_reconnect(client))
				continue;
			break;
		}

		uint8_t resp_len_buf[4];
		if (!read_exact(client->fd, resp_len_buf, 4)) {
			fprintf(stderr, "%s\n", ERROR_SOCKET_RECEIVE);
			if (attempt == 0 && aerospace_reconnect(client))
				continue;
			break;
		}

		uint32_t resp_len = get_le_u32(resp_len_buf);
		if (resp_len > READ_BUFFER_SIZE) {
			fprintf(stderr, "Error: Response too large (%u bytes)\n", resp_len);
			break;
		}

		if (!read_exact(client->fd, (uint8_t*)client->read_buf, resp_len)) {
			fprintf(stderr, "%s\n", ERROR_SOCKET_RECEIVE);
			if (attempt == 0 && aerospace_reconnect(client))
				continue;
			break;
		}

		yyjson_doc* resp_doc = yyjson_read_opts(client->read_buf, resp_len, 0, NULL, NULL);
		if (!resp_doc) {
			fprintf(stderr, "Error: Failed to parse server response\n");
			break;
		}

		yyjson_val* resp_root = yyjson_doc_get_root(resp_doc);
		int exitCode = -1;
		yyjson_val* exitCodeItem = yyjson_obj_get(resp_root, "exitCode");
		if (yyjson_is_int(exitCodeItem)) {
			exitCode = (int)yyjson_get_int(exitCodeItem);
		} else {
			fprintf(stderr, "Response does not contain valid %s field\n", "exitCode");
			yyjson_doc_free(resp_doc);
			break;
		}

		if (exitCode != 0) {
			yyjson_val* output_item = yyjson_obj_get(resp_root, "stderr");
			if (yyjson_is_str(output_item)) {
				result = strdup(yyjson_get_str(output_item));
			}
		} else if (expected_output_field) {
			yyjson_val* output_item = yyjson_obj_get(resp_root, expected_output_field);
			if (yyjson_is_str(output_item)) {
				result = strdup(yyjson_get_str(output_item));
			}
		}

		yyjson_doc_free(resp_doc);
		break;
	}

	pthread_mutex_unlock(&g_socket_mutex);
	free((void*)json_str);
	return result;
}

aerospace* aerospace_new(const char* socketPath)
{
	aerospace* client = malloc(sizeof(aerospace));
	client->fd = -1;
	client->use_cli_fallback = false;

	if (socketPath)
		client->socket_path = strdup(socketPath);
	else
		client->socket_path = get_default_socket_path();

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, client->socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	// AeroSpace may not be ready when we start (e.g. at login). Retry the
	// connect with bounded backoff before giving up and falling back to CLI,
	// otherwise we get stuck in CLI mode for the entire session.
	int connect_errno = 0;
	for (int attempt = 0; attempt < SOCKET_CONNECT_MAX_ATTEMPTS; attempt++) {
		errno = 0;
		client->fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (client->fd < 0) {
			int socket_errno = errno;
			free(client->socket_path);
			free(client);
			errno = socket_errno;
			fatal_error("%s", ERROR_SOCKET_CREATE);
		}

		errno = 0;
		if (connect(client->fd, (struct sockaddr*)&addr, sizeof(addr)) == 0 && aerospace_handshake(client->fd)) {
			connect_errno = 0;
			break;
		}
		connect_errno = errno ? errno : EPROTO;
		close(client->fd);
		client->fd = -1;
		if (attempt + 1 < SOCKET_CONNECT_MAX_ATTEMPTS) {
			usleep(SOCKET_CONNECT_RETRY_USEC);
		}
	}

	if (connect_errno != 0) {
		fprintf(stderr, WARN_CLI_FALLBACK, client->socket_path, strerror(connect_errno), connect_errno);
		client->use_cli_fallback = true;
	}

	return client;
}

int aerospace_is_initialized(aerospace* client)
{
	return (client && (client->fd >= 0 || client->use_cli_fallback));
}

void aerospace_close(aerospace* client)
{
	if (client) {
		if (client->fd >= 0) {
			errno = 0;
			if (close(client->fd) < 0) {
				fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_CLOSE, strerror(errno), errno);
			}
			client->fd = -1;
		}
		free(client->socket_path);
		client->socket_path = NULL;
		free(client);
	}
}

char* aerospace_switch(aerospace* client, const char* direction)
{
	return aerospace_workspace(client, 0, direction, "");
}

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command,
	const char* stdin_payload)
{
	const char* args[3] = { "workspace", ws_command };
	int arg_count = 2;
	if (wrap_around) {
		args[arg_count++] = "--wrap-around";
	}
	return execute_aerospace_command(client, args, arg_count, stdin_payload, NULL);
}

char* aerospace_list_workspaces(aerospace* client, bool include_empty)
{
	if (include_empty) {
		const char* args[] = { "list-workspaces", "--monitor", "focused" };
		return execute_aerospace_command(client, args, 3, "", "stdout");
	} else {
		const char* args[] = { "list-workspaces", "--monitor", "focused", "--empty", "no" };
		return execute_aerospace_command(client, args, 5, "", "stdout");
	}
}
