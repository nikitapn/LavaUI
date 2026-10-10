// lava-index-query: asks a running lava-index, the way LavaFind will.
//
//   lava-index-query search <words…> [--category videos] [--limit 20]
//   lava-index-query recent [--limit 20]
//   lava-index-query status
//   lava-index-query rescan <root>
//   lava-index-query opened <path>
//   lava-index-query watch            # print IndexChanged as it arrives
//
// For debugging and for scripts; also the shortest proof that the IDL works
// from outside the daemon.

#include "gen/index.hpp"

#include <nprpc/nprpc.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace idl = lava::index;

namespace {

std::string referencePath() {
  if (const char *p = std::getenv("LAVA_INDEX_IOR"); p && *p) return p;
  const char *dir = std::getenv("XDG_RUNTIME_DIR");
  return std::string(dir && *dir ? dir : "/tmp") + "/lava-index.ior";
}

std::string when(int64_t secs) {
  if (secs == 0) return "-";
  char buf[32];
  const time_t t = secs;
  std::strftime(buf, sizeof buf, "%Y-%m-%d %H:%M", std::localtime(&t));
  return buf;
}

std::string size(uint64_t bytes) {
  char buf[32];
  if (bytes >= 1ull << 30) std::snprintf(buf, sizeof buf, "%.1f GB", bytes / double(1ull << 30));
  else if (bytes >= 1ull << 20) std::snprintf(buf, sizeof buf, "%.1f MB", bytes / double(1ull << 20));
  else if (bytes >= 1024) std::snprintf(buf, sizeof buf, "%.0f KB", bytes / 1024.0);
  else std::snprintf(buf, sizeof buf, "%llu B", static_cast<unsigned long long>(bytes));
  return buf;
}

void print(const idl::Hit &h) {
  const char *badge = h.kind == idl::EntryKind::directory ? "DIR" : h.ext.empty() ? "-" : h.ext.c_str();
  // The highlight, as the window would draw it: [brackets] around the match
  // inside the last component.
  std::string shown = h.path;
  if (h.matchLength > 0) {
    const size_t nameAt = h.path.rfind('/') + 1;
    const size_t a = nameAt + h.matchStart, b = a + h.matchLength;
    if (b <= shown.size()) shown = shown.substr(0, a) + "[" + shown.substr(a, b - a) + "]" + shown.substr(b);
  }
  std::printf("%-5s %10s  %s  %s%s\n", badge, h.kind == idl::EntryKind::directory ? "" : size(h.size).c_str(),
              when(h.mtime).c_str(), shown.c_str(),
              h.lastOpened ? ("   (opened " + when(h.lastOpened) + ")").c_str() : "");
}

idl::Category parseCategory(const std::string &s) {
  if (s == "folders") return idl::Category::folders;
  if (s == "documents") return idl::Category::documents;
  if (s == "images") return idl::Category::images;
  if (s == "videos") return idl::Category::videos;
  if (s == "audio") return idl::Category::audio;
  if (s == "archives") return idl::Category::archives;
  return idl::Category::any;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: lava-index-query search|recent|status|rescan|opened|watch …\n");
    return 2;
  }
  const std::string command = argv[1];
  std::vector<std::string> words;
  idl::Category category = idl::Category::any;
  uint32_t limit = 20;
  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--category" && i + 1 < argc) category = parseCategory(argv[++i]);
    else if (a == "--limit" && i + 1 < argc) limit = static_cast<uint32_t>(std::atoi(argv[++i]));
    else words.push_back(a);
  }

  std::ifstream file(referencePath());
  std::stringstream ior;
  ior << file.rdbuf();
  if (!file || ior.str().empty()) {
    std::fprintf(stderr, "lava-index-query: no daemon (%s)\n", referencePath().c_str());
    return 1;
  }

  nprpc::Rpc *rpc = nprpc::RpcBuilder().set_log_level(nprpc::LogLevel::error).build();
  rpc->start_thread_pool(2);
  nprpc::Object *raw = nprpc::Object::from_string(ior.str());
  if (raw == nullptr) {
    std::fprintf(stderr, "lava-index-query: unreadable reference\n");
    return 1;
  }
  nprpc::ObjectPtr<idl::Index> index(nprpc::narrow<idl::Index>(raw));
  if (!index) {
    std::fprintf(stderr, "lava-index-query: the reference is not an Index\n");
    return 1;
  }

  int rc = 0;
  try {
    if (command == "search") {
      std::string query;
      for (const auto &w : words) query += (query.empty() ? "" : " ") + w;
      const auto t0 = std::chrono::steady_clock::now();
      const idl::SearchResult r = index->Search(query, category, limit);
      const double ms =
          std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
      for (const auto &h : r.hits) print(h);
      std::printf("-- %zu hits%s, %.2f ms round trip\n", r.hits.size(),
                  r.truncated ? " (more matched)" : "", ms);
    } else if (command == "recent") {
      for (const auto &h : index->Recent(limit)) print(h);
    } else if (command == "status") {
      const idl::IndexStatus s = index->Status();
      for (const auto &r : s.roots) {
        std::printf("%-40s %-8s %-10s %-9s %10llu entries  reconciled %s\n", r.path.c_str(),
                    r.online ? "online" : "OFFLINE", r.watched ? "watched" : "unwatched",
                    r.scanning ? "scanning" : "", static_cast<unsigned long long>(r.entries),
                    when(r.lastReconcile).c_str());
      }
    } else if (command == "rescan" && words.size() == 1) {
      index->Rescan(words[0]);
    } else if (command == "opened" && words.size() == 1) {
      index->NoteOpened(words[0], "lava-index-query");
    } else if (command == "watch") {
      auto [writer, reader] = index->SubscribeChanges();
      while (auto msg = reader.read_next()) {
        std::printf("changed serial=%u%s\n", msg->serial, msg->recentOnly ? " (recent only)" : "");
        std::fflush(stdout);
        idl::IndexChangedAck ack{};
        ack.serial = msg->serial;
        writer.write(ack);
      }
    } else {
      std::fprintf(stderr, "lava-index-query: unknown command or wrong arguments\n");
      rc = 2;
    }
  } catch (const idl::RootNotFound &e) {
    std::fprintf(stderr, "lava-index-query: not a root: %s\n", e.path.c_str());
    rc = 1;
  } catch (const nprpc::Exception &e) {
    std::fprintf(stderr, "lava-index-query: %s\n", e.what());
    rc = 1;
  }
  index.reset();
  rpc->destroy();
  return rc;
}
