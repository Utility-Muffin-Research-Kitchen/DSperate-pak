// Host test for DSperate's account bridge (patch 0005, ra_account_bridge.cpp):
// what the emulator actually does with a handoff, and what it refuses to do
// when a write fails.
//
// The fixtures prove which handoffs are well formed and state_test.cpp proves
// the transition table. This file drives the bridge itself, compiled from the
// patched source exactly as the MLP1 build compiles it, through:
//
//   - an explicit per-game / per-launch "achievements off" (G16);
//   - the checked token writer interrupted at every boundary -- open, write
//     (a full card, and a short write followed by one), fsync, close, rename --
//     and the accepted marker only after it (G18);
//   - a crash between the token and the accepted marker;
//   - a corrupt marker, a corrupt token file, a missing managed directory;
//   - the pop-up notices a failure produces (G20);
//   - an unmanaged sign-in, which persists nothing (G22);
//   - sign-out, suppression, the single password retry, and the scrub.
//
// Faults are injected by interposing the libc calls the writers make (open,
// write, fsync, close, rename, fopen, fwrite, fflush, fclose, unlink): this
// executable's definitions win at link time over the C library's, so the
// shipped code runs unmodified, with no test hook compiled into it. Synthetic
// credentials only.
#include "cheevos/ra_account.h"

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using namespace ds::cheevos::ra_account;

// ---------------------------------------------------------------------------
// libc fault injection

namespace {
struct Fault {
  const char *fn = nullptr;  // which call fails
  int skip = 0;              // let this many matching calls through first
  int err = 0;               // errno to report
  bool shortWrite = false;   // write(2): answer one byte before failing
};
Fault g_fault;
int g_calls = 0;

bool trip(const char *fn) {
  if (g_fault.fn == nullptr || std::strcmp(g_fault.fn, fn) != 0) return false;
  if (g_fault.skip > 0) {
    g_fault.skip--;
    return false;
  }
  if (g_fault.shortWrite) return false;  // handled by write() itself
  g_fault.fn = nullptr;
  g_calls++;
  return true;
}

template <typename F>
F real(const char *name) {
  void *sym = dlsym(RTLD_NEXT, name);
  if (sym == nullptr) {
    std::fprintf(stderr, "cannot resolve %s\n", name);
    std::abort();
  }
  return reinterpret_cast<F>(sym);
}

void inject(const char *fn, int err, int skip = 0) {
  g_fault = Fault{};
  g_fault.fn = fn;
  g_fault.err = err;
  g_fault.skip = skip;
  g_calls = 0;
}
void clearFault() { g_fault = Fault{}; }
}  // namespace

extern "C" {
int open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = static_cast<mode_t>(va_arg(ap, int));
    va_end(ap);
  }
  if (trip("open")) { errno = g_fault.err; return -1; }
  return real<int (*)(const char *, int, ...)>("open")(path, flags, mode);
}
ssize_t write(int fd, const void *buf, size_t n) {
  if (g_fault.fn != nullptr && std::strcmp(g_fault.fn, "write") == 0 && g_fault.skip == 0 &&
      g_fault.shortWrite && n > 1) {
    // A card that takes one byte and then reports it is full.
    g_fault.shortWrite = false;
    return real<ssize_t (*)(int, const void *, size_t)>("write")(fd, buf, 1);
  }
  if (trip("write")) { errno = g_fault.err; return -1; }
  return real<ssize_t (*)(int, const void *, size_t)>("write")(fd, buf, n);
}
int fsync(int fd) {
  if (trip("fsync")) { errno = g_fault.err; return -1; }
  return real<int (*)(int)>("fsync")(fd);
}
int close(int fd) {
  if (trip("close")) {
    // The descriptor is still released, as a failing close(2) does.
    real<int (*)(int)>("close")(fd);
    errno = g_fault.err;
    return -1;
  }
  return real<int (*)(int)>("close")(fd);
}
int rename(const char *from, const char *to) {
  if (trip("rename")) { errno = g_fault.err; return -1; }
  return real<int (*)(const char *, const char *)>("rename")(from, to);
}
int unlink(const char *path) {
  if (trip("unlink")) { errno = g_fault.err; return -1; }
  return real<int (*)(const char *)>("unlink")(path);
}
FILE *fopen(const char *path, const char *mode) {
  if (trip("fopen")) { errno = g_fault.err; return nullptr; }
  return real<FILE *(*)(const char *, const char *)>("fopen")(path, mode);
}
size_t fwrite(const void *buf, size_t size, size_t count, FILE *f) {
  if (trip("fwrite")) { errno = g_fault.err; return 0; }
  return real<size_t (*)(const void *, size_t, size_t, FILE *)>("fwrite")(buf, size, count, f);
}
int fflush(FILE *f) {
  if (trip("fflush")) { errno = g_fault.err; return EOF; }
  return real<int (*)(FILE *)>("fflush")(f);
}
int fclose(FILE *f) {
  if (trip("fclose")) {
    real<int (*)(FILE *)>("fclose")(f);
    errno = g_fault.err;
    return EOF;
  }
  return real<int (*)(FILE *)>("fclose")(f);
}
}

// ---------------------------------------------------------------------------
// Harness

static int failures = 0;
static int checks = 0;
static std::string root;
static int dirCounter = 0;

static void check(bool condition, const std::string &what) {
  checks++;
  if (condition) {
    std::printf("ok   %s\n", what.c_str());
  } else {
    std::printf("FAIL %s\n", what.c_str());
    failures++;
  }
}

static const char *const kPassword = "correct horse battery";
static const char *const kAllVars[] = {
    "UMRK_RA_ACCOUNT_VERSION", "UMRK_RA_ACCOUNT_STATE",   "UMRK_RA_ACCOUNT_USERNAME",
    "UMRK_RA_ACCOUNT_PASSWORD", "UMRK_RA_ACCOUNT_REVISION", "JAWAKA_CHEEVOS_USERNAME",
    "JAWAKA_CHEEVOS_PASSWORD",
};

static std::string readFile(const std::string &file) {
  FILE *f = fopen(file.c_str(), "rb");
  if (f == nullptr) return "<absent>";
  std::string content;
  char buffer[512];
  size_t n;
  while ((n = fread(buffer, 1, sizeof buffer, f)) > 0) content.append(buffer, n);
  fclose(f);
  return content;
}

static void writeFile(const std::string &file, const std::string &content) {
  FILE *f = fopen(file.c_str(), "wb");
  if (f == nullptr) {
    std::fprintf(stderr, "cannot write %s\n", file.c_str());
    std::exit(2);
  }
  fwrite(content.data(), 1, content.size(), f);
  fclose(f);
}

static bool exists(const std::string &file) {
  struct stat st;
  return ::stat(file.c_str(), &st) == 0;
}

static std::string freshDir() {
  const std::string dir = root + "/managed-" + std::to_string(++dirCounter);
  if (mkdir(dir.c_str(), 0755) != 0) {
    std::fprintf(stderr, "cannot create %s\n", dir.c_str());
    std::exit(2);
  }
  return dir;
}

static std::string marker(const std::string &dir) { return dir + "/.umrk-ra-account"; }
static std::string token(const std::string &dir) { return dir + "/cheevos.token"; }

static std::string markerText(const char *state, long long revision, const std::string &account) {
  return std::string("umrk-ra-account 1\nstate ") + state + "\nrevision " +
         std::to_string(revision) + "\naccount " + account + "\n";
}

static void clearVars() {
  for (const char *name : kAllVars) unsetenv(name);
}

static void configured(const std::string &user, long long revision) {
  clearVars();
  setenv("UMRK_RA_ACCOUNT_VERSION", "1", 1);
  setenv("UMRK_RA_ACCOUNT_STATE", "configured", 1);
  setenv("UMRK_RA_ACCOUNT_USERNAME", user.c_str(), 1);
  setenv("UMRK_RA_ACCOUNT_PASSWORD", kPassword, 1);
  setenv("UMRK_RA_ACCOUNT_REVISION", std::to_string(revision).c_str(), 1);
}

static void signedOut(long long revision) {
  clearVars();
  setenv("UMRK_RA_ACCOUNT_VERSION", "1", 1);
  setenv("UMRK_RA_ACCOUNT_STATE", "signed-out", 1);
  setenv("UMRK_RA_ACCOUNT_REVISION", std::to_string(revision).c_str(), 1);
}

// A new process: the bridge forgets everything, then consumes this launch.
static void launch(const std::string &dir, bool achievementsOff = false) {
  resetForTesting();
  captureEnv();
  setManagedDir(dir);
  import(achievementsOff);
}

static bool envScrubbed() {
  for (const char *name : kAllVars)
    if (getenv(name) != nullptr) return false;
  return true;
}

static bool noticesSecretFree(const std::vector<Notice> &notices, const std::string &tokenText) {
  for (const Notice &n : notices) {
    const std::string all = n.text + "\n" + n.detail;
    if (all.find(kPassword) != std::string::npos) return false;
    if (!tokenText.empty() && all.find(tokenText) != std::string::npos) return false;
  }
  return true;
}

static bool anyNoticeContains(const std::vector<Notice> &notices, const std::string &needle) {
  for (const Notice &n : notices)
    if ((n.text + " " + n.detail).find(needle) != std::string::npos) return true;
  return false;
}

// Seed an accepted account (the state after a successful earlier launch).
static void seedAccepted(const std::string &dir, const std::string &user, long long revision,
                         const std::string &tok) {
  writeFile(marker(dir), markerText("accepted", revision, user));
  writeFile(token(dir), user + "\n" + tok + "\n");
}

// ---------------------------------------------------------------------------

static void testScrubHappensAtCapture() {
  const std::string dir = freshDir();
  configured("player-one", 1);
  setenv("JAWAKA_CHEEVOS_USERNAME", "player-one", 1);
  setenv("JAWAKA_CHEEVOS_PASSWORD", kPassword, 1);
  resetForTesting();
  captureEnv();
  check(envScrubbed(), "scrub: captureEnv removes every UMRK_RA_ACCOUNT_* and JAWAKA_CHEEVOS_* variable");
  setManagedDir(dir);
  import(false);
  std::string user, password;
  check(!isManaged() && !takePendingLogin(user, password),
        "scrub: a leaked RetroArch pair refuses the handoff (nothing imported)");
  check(readFile(marker(dir)) == "<absent>", "scrub: a refused handoff writes no marker");
  check(noticesSecretFree(takeNotices(), ""), "scrub: no notice carries the password");
}

static void testExplicitOffWins() {
  // G16: an explicit per-game or per-launch "achievements off" beats a managed
  // account. The handoff is consumed and scrubbed, nothing signs in, and the
  // marker and token are left byte for byte as they were.
  const std::string dir = freshDir();
  seedAccepted(dir, "player-one", 3, "tok-3");
  const std::string markerBefore = readFile(marker(dir));
  const std::string tokenBefore = readFile(token(dir));

  configured("player-one", 4);  // a new revision: without the switch this would import
  launch(dir, /*achievementsOff=*/true);
  check(envScrubbed(), "off: the handoff is still consumed and unset");
  std::string user, password;
  check(!takePendingLogin(user, password), "off: no password login is offered");
  check(!loadManagedToken(user, password), "off: the stored token is not offered");
  check(!isManaged() && !isSuppressed(), "off: the session is not managed");
  check(!achievementsOn(true, false), "off: cheevos.enabled = false / --no-cheevos keeps achievements off");
  check(readFile(marker(dir)) == markerBefore, "off: the marker is untouched");
  check(readFile(token(dir)) == tokenBefore, "off: the token is untouched");
  check(takeNotices().empty(), "off: nothing to report");

  // The same account with no explicit setting: the default stays enabled.
  launch(dir, false);
  check(isManaged() && achievementsOn(false, false),
        "default: a configured Leaf account turns achievements on without a setting");
  check(achievementsOn(true, true), "default: an explicit cheevos.enabled = true stays on");
  check(!achievementsOn(true, false), "default: an explicit off still wins while managed");

  // Unmanaged: upstream's default of off, and an explicit on still works.
  clearVars();
  launch(freshDir(), false);
  check(!achievementsOn(false, false), "unmanaged: achievements stay off by default");
  check(achievementsOn(true, true), "unmanaged: an explicit cheevos.enabled = true turns them on");
}

static void testFirstImportAndReuse() {
  const std::string dir = freshDir();
  configured("player-one", 1);
  launch(dir);
  check(readFile(marker(dir)) == markerText("pending", 1, "player-one"),
        "import: pending is written before any credential changes");
  std::string user, password;
  check(takePendingLogin(user, password) && user == "player-one" && password == kPassword,
        "import: the native password login gets the snapshot once");
  check(!takePendingLogin(user, password), "import: and only once");
  check(!isTokenLoginAllowed(), "import: no stored token is used before the login succeeds");

  check(commitLogin("player-one", "tok-1"), "import: a verified login is committed");
  check(readFile(token(dir)) == "player-one\ntok-1\n", "import: the token is written in DSperate's format");
  struct stat st;
  check(::stat(token(dir).c_str(), &st) == 0 && (st.st_mode & 0777) == 0600,
        "import: the token file is 0600");
  check(readFile(marker(dir)) == markerText("accepted", 1, "player-one"),
        "import: the revision is accepted after the token is durable");
  check(statusLine() == "accepted", "import: status accepted");
  check(!exists(token(dir) + ".tmp") && !exists(marker(dir) + ".tmp"), "import: no temporary left");

  configured("player-one", 1);
  launch(dir);
  check(isTokenLoginAllowed() && loadManagedToken(user, password) && user == "player-one" &&
            password == "tok-1",
        "reuse: the next launch reuses the accepted token");
  check(!takePendingLogin(user, password), "reuse: no password login");
  check(takeTokenRetry(user, password) && password == kPassword,
        "reuse: a rejected token gets one password retry");
  check(!takeTokenRetry(user, password), "reuse: and never a second one");
}

// G18: the token writer, interrupted at every boundary. The previous token
// survives, the marker stays pending, the failure is reported, and the next
// launch imports again instead of trusting either file.
static void testTokenWriteBoundaries() {
  struct Case {
    const char *fn;
    int err;
    bool shortWrite;
    const char *label;
    const char *step;
  };
  const Case cases[] = {
      {"open", EACCES, false, "open refused", "open"},
      {"write", ENOSPC, false, "low storage (write ENOSPC)", "write"},
      {"write", ENOSPC, true, "short write, then a full card", "write"},
      {"fsync", EIO, false, "fsync fails", "fsync"},
      {"close", EIO, false, "close fails", "close"},
      {"rename", EIO, false, "rename fails", "rename"},
  };
  for (const Case &c : cases) {
    const std::string dir = freshDir();
    seedAccepted(dir, "player-one", 1, "tok-1");
    configured("player-one", 2);
    launch(dir);
    std::string user, password;
    takePendingLogin(user, password);
    takeNotices();

    inject(c.fn, c.err);
    if (c.shortWrite) g_fault.shortWrite = true;
    const bool committed = commitLogin("player-one", "tok-2");
    const int fired = g_calls;
    clearFault();
    const std::string what = std::string("token write, ") + c.label + ": ";
    check(fired == 1 || c.shortWrite, what + "the fault fired");
    check(!committed, what + "commit reports failure");
    check(readFile(token(dir)) == "player-one\ntok-1\n", what + "the previous token is intact");
    check(!exists(token(dir) + ".tmp"), what + "no temporary is left behind");
    check(readFile(marker(dir)) == markerText("pending", 2, "player-one"),
          what + "the revision stays pending, never accepted");
    check(statusLine() == "token-save-failed" && isSuppressed(), what + "status token-save-failed");
    const std::vector<Notice> notices = takeNotices();
    check(anyNoticeContains(notices, "could not be saved") && anyNoticeContains(notices, c.step),
          what + "a pop-up notice names the failed step");
    check(noticesSecretFree(notices, "tok-2"), what + "the notice carries no secret");

    configured("player-one", 2);
    launch(dir);
    check(!loadManagedToken(user, password) && takePendingLogin(user, password),
          what + "the next launch imports again");
  }
}

// A crash, or a failed marker write, between the token save and the accepted
// marker: the token is durable but the revision is not accepted, so the next
// launch logs in again rather than trusting an unrecorded state.
static void testAcceptMarkerBoundaries() {
  const char *fns[] = {"fopen", "fwrite", "fflush", "fsync", "fclose", "rename"};
  for (const char *fn : fns) {
    const std::string dir = freshDir();
    configured("player-one", 1);
    launch(dir);
    std::string user, password;
    takePendingLogin(user, password);
    takeNotices();
    // The token writer's own fsync and rename come first.
    const int skip = (std::strcmp(fn, "fsync") == 0 || std::strcmp(fn, "rename") == 0) ? 1 : 0;
    inject(fn, ENOSPC, skip);
    commitLogin("player-one", "tok-1");
    const int fired = g_calls;
    clearFault();
    const std::string what = std::string("accept marker, ") + fn + " fails: ";
    check(fired == 1, what + "the fault fired");
    check(readFile(token(dir)) == "player-one\ntok-1\n", what + "the token was saved first");
    check(readFile(marker(dir)) == markerText("pending", 1, "player-one"),
          what + "the marker still says pending");
    check(!exists(marker(dir) + ".tmp"), what + "no temporary marker is left");
    check(statusLine() == "accept-marker-failed", what + "status accept-marker-failed");
    check(anyNoticeContains(takeNotices(), "imported again"), what + "the player is told");
    configured("player-one", 1);
    launch(dir);
    check(takePendingLogin(user, password), what + "the next launch imports again");
  }
}

// The pending marker cannot be written at import: nothing changes on disk, no
// login runs, and the previous account is not used either.
static void testPendingMarkerBoundaries() {
  const char *fns[] = {"fopen", "fwrite", "fflush", "fsync", "fclose", "rename"};
  for (const char *fn : fns) {
    const std::string dir = freshDir();
    seedAccepted(dir, "player-one", 1, "tok-1");
    const std::string before = readFile(marker(dir));
    configured("player-one", 2);
    // import() reads the marker and the token (fopen, fclose) before it writes.
    const int skip = (std::strcmp(fn, "fopen") == 0 || std::strcmp(fn, "fclose") == 0) ? 2 : 0;
    inject(fn, ENOSPC, skip);
    launch(dir);
    const int fired = g_calls;
    clearFault();
    const std::string what = std::string("pending marker, ") + fn + " fails: ";
    std::string user, password;
    check(fired == 1, what + "the fault fired");
    check(readFile(marker(dir)) == before, what + "the previous marker is intact");
    check(readFile(token(dir)) == "player-one\ntok-1\n", what + "the previous token is intact");
    check(!takePendingLogin(user, password) && !loadManagedToken(user, password),
          what + "nothing authenticates, not even the old token");
    check(isSuppressed() && statusLine() == "pending-marker-failed",
          what + "status pending-marker-failed");
    const std::vector<Notice> notices = takeNotices();
    check(anyNoticeContains(notices, "Could not prepare"), what + "a pop-up notice is queued");
    check(noticesSecretFree(notices, "tok-1"), what + "the notice carries no secret");
  }
}

static void testMissingManagedDir() {
  configured("player-one", 1);
  const std::string missing = root + "/no-such-directory/retroachievements";
  launch(missing);
  std::string user, password;
  check(!takePendingLogin(user, password), "missing dir: no login");
  check(isSuppressed() && statusLine() == "pending-marker-failed", "missing dir: suppressed and reported");
  check(!exists(root + "/no-such-directory"), "missing dir: nothing is created");
  check(anyNoticeContains(takeNotices(), "Could not prepare"), "missing dir: a notice is queued");

  configured("player-one", 1);
  launch("");
  check(isSuppressed() && !takePendingLogin(user, password),
        "no dir argument: a handoff without --managed-account-dir never authenticates");
  check(anyNoticeContains(takeNotices(), "no managed account directory"),
        "no dir argument: the notice says why");
}

static void testCorruption() {
  // A damaged marker is managed state: the next launch imports again.
  const std::string dir = freshDir();
  writeFile(marker(dir), "umrk-ra-account 1\nstate accep");
  writeFile(token(dir), "player-one\ntok-1\n");
  configured("player-one", 1);
  launch(dir);
  std::string user, password;
  check(takePendingLogin(user, password), "corrupt marker: imports again");
  check(readFile(marker(dir)) == markerText("pending", 1, "player-one"),
        "corrupt marker: replaced by a pending marker");

  // A damaged token file is never reused, whatever the marker says.
  const std::string dir2 = freshDir();
  writeFile(marker(dir2), markerText("accepted", 1, "player-one"));
  writeFile(token(dir2), "player-one\n");
  configured("player-one", 1);
  launch(dir2);
  check(!loadManagedToken(user, password) && takePendingLogin(user, password),
        "truncated token: not reused, imports again");

  // A token file that belongs to someone else is never used.
  const std::string dir3 = freshDir();
  writeFile(marker(dir3), markerText("accepted", 1, "player-one"));
  writeFile(token(dir3), "someone-else\ntok-x\n");
  configured("player-one", 1);
  launch(dir3);
  check(!loadManagedToken(user, password) && takePendingLogin(user, password),
        "foreign token: not reused, imports again");
}

static void testSignOut() {
  const std::string dir = freshDir();
  seedAccepted(dir, "player-one", 1, "tok-1");
  signedOut(2);
  launch(dir);
  check(!exists(token(dir)), "sign-out: the managed token is removed");
  check(readFile(marker(dir)) == markerText("signed-out", 2, ""), "sign-out: the revision is recorded");
  std::string user, password;
  check(!loadManagedToken(user, password) && !takePendingLogin(user, password),
        "sign-out: nothing authenticates");

  const std::string dir2 = freshDir();
  seedAccepted(dir2, "player-one", 1, "tok-1");
  signedOut(2);
  inject("unlink", EACCES);
  launch(dir2);
  clearFault();
  check(readFile(marker(dir2)) == markerText("signed-out", 2, ""),
        "sign-out, token removal fails: the sign-out is still recorded");
  check(statusLine() == "sign-out-token-failed" && isSuppressed(),
        "sign-out, token removal fails: reported and suppressed");
  check(anyNoticeContains(takeNotices(), "Could not remove"), "sign-out, token removal fails: a notice is queued");
  configured("player-one", 3);
  launch(dir2);
  check(!loadManagedToken(user, password), "sign-out, token removal fails: the old token is never reused");
}

static void testSuppressed() {
  const std::string dir = freshDir();
  seedAccepted(dir, "player-one", 1, "tok-1");
  const std::string before = readFile(marker(dir));
  clearVars();  // an unauthorized launch, or a launcher without the contract
  launch(dir);
  std::string user, password;
  check(isSuppressed() && !loadManagedToken(user, password),
        "no handoff with managed state: suppressed, the token is not used");
  check(readFile(marker(dir)) == before && readFile(token(dir)) == "player-one\ntok-1\n",
        "no handoff with managed state: nothing durable is erased");
  check(anyNoticeContains(takeNotices(), "unavailable"), "no handoff with managed state: a notice is queued");
}

static void testLoginFailure() {
  const std::string dir = freshDir();
  configured("player-one", 1);
  launch(dir);
  std::string user, password;
  takePendingLogin(user, password);
  reportLoginFailure("login-failed", "Invalid username/password");
  check(isSuppressed() && statusLine() == "login-failed", "rejected login: reported");
  check(readFile(marker(dir)) == markerText("pending", 1, "player-one"),
        "rejected login: the revision is not accepted");
  check(!takeTokenRetry(user, password), "rejected login: no retry loop");
}

// G22: an unmanaged native sign-in is session-only, as upstream's is. Nothing
// is written -- not into the managed directory, and not into the per-game
// config directory the wrapper points XDG_CONFIG_HOME at.
static void testUnmanagedSignInPersistsNothing() {
  const std::string dir = freshDir();
  const std::string xdg = freshDir();
  setenv("XDG_CONFIG_HOME", xdg.c_str(), 1);
  clearVars();
  launch(dir);
  check(!isManaged() && !isSuppressed(), "unmanaged: the launch is native");
  check(commitLogin("native-user", "native-token"), "unmanaged: a native sign-in succeeds");
  check(!exists(token(dir)) && !exists(marker(dir)), "unmanaged: nothing in the managed directory");
  check(!exists(xdg + "/dsperate/cheevos.token") && !exists(xdg + "/cheevos.token"),
        "unmanaged: nothing in the per-game config directory");
  unsetenv("XDG_CONFIG_HOME");
}

static void testTokenWriterRefusesBadInput() {
  const std::string dir = freshDir();
  std::string err;
  check(!writeTokenFile(dir, "player\nx", "tok", err), "token writer: refuses a line break in the name");
  check(!writeTokenFile(dir, "player", "", err), "token writer: refuses an empty token");
  check(!exists(token(dir)), "token writer: nothing written for bad input");
  check(!writeTokenFile(root + "/missing/dir", "player", "tok", err) && !err.empty(),
        "token writer: a missing directory fails with a reason");
}

int main() {
  char name[] = "/tmp/dsperate-ra-bridge-XXXXXX";
  const char *made = mkdtemp(name);
  if (made == nullptr) {
    std::fprintf(stderr, "cannot create a temporary directory\n");
    return 2;
  }
  root = made;
  // The bridge logs to stderr; keep the test output to the verdicts.
  if (getenv("RA_BRIDGE_TEST_VERBOSE") == nullptr) {
    FILE *quiet = freopen("/dev/null", "w", stderr);
    (void)quiet;
  }

  testScrubHappensAtCapture();
  testExplicitOffWins();
  testFirstImportAndReuse();
  testTokenWriteBoundaries();
  testAcceptMarkerBoundaries();
  testPendingMarkerBoundaries();
  testMissingManagedDir();
  testCorruption();
  testSignOut();
  testSuppressed();
  testLoginFailure();
  testUnmanagedSignInPersistsNothing();
  testTokenWriterRefusesBadInput();

  if (failures != 0) {
    std::printf("%d of %d account bridge checks failed\n", failures, checks);
    return 1;
  }
  std::printf("All %d account bridge checks passed.\n", checks);
  return 0;
}
