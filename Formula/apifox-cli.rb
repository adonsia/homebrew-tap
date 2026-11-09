class ApifoxCli < Formula
  desc "Official Apifox CLI for API documentation and testing"
  homepage "https://apifox.com/apifox-cli/"
  url "https://registry.npmjs.org/apifox-cli/-/apifox-cli-2.2.11.tgz"
  sha256 "4d0dd00f14329b6a2f1a35c693c121cc6da26fe4fa9c357fe870dde8b1e0ac39"
  license :cannot_represent
  revision 1

  depends_on "libuv" => :build
  depends_on "python@3.14" => :build
  depends_on "krb5"
  depends_on "node"

  on_macos do
    on_arm do
      resource "clidriver" do
        url "https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/v12.1.2/macarm64_odbc_cli.tar.gz"
        sha256 "3af2f542a43cc48b3c88b6319eeba8d6df92de51da16cd58bd16beebe17f0fdd"
      end
    end
    on_intel do
      resource "clidriver" do
        url "https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/v11.5.9/macos64_odbc_cli.tar.gz"
        sha256 "8422b3ec74564ab737fc7a3caf173ab378d4654d1f2093bfca7db0a93ce154d8"
      end
    end
  end

  resource "oracledb-source" do
    url "https://github.com/oracle/node-oracledb/releases/download/v5.5.0/oracledb-src-5.5.0.tgz"
    sha256 "9e114c06180a96db18f2e99588e8c5aae0957a6be2ef1cc5950cd11c953c5b44"
  end

  resource "npm-shrinkwrap" do
    url "https://github.com/adonsia/homebrew-tap/releases/download/apifox-cli-2.2.11-1/npm-shrinkwrap.json"
    sha256 "6da04a791531973c732eefee96c3340c0ab17db950a49b52981dc1b1194a605b"
  end

  def install
    resource("npm-shrinkwrap").stage { buildpath.install "npm-shrinkwrap.json" }
    # Keep lifecycle scripts disabled: build only the reviewed native modules below.
    system "npm", "ci", *std_npm_args(prefix: false), "--omit=dev"
    libexec.install Dir["*"]
    modules = libexec/"node_modules"

    # The registry package includes only Intel macOS binaries, not the source.
    rm_r modules/"oracledb"
    resource("oracledb-source").stage modules/"oracledb"
    if OS.mac?
      resource("clidriver").stage modules/"ibm_db/installer/clidriver"
    else
      # IBM still requires libxml2.so.2, unavailable on Ubuntu 26.04.
      rm_r modules/"ibm_db"
    end

    ENV["PYTHON"] = formula_opt_bin("python@3.14")/"python3.14"
    ENV.append "CFLAGS", "-I#{formula_opt_include("libuv")}"
    ENV.append "CXXFLAGS", "-I#{formula_opt_include("libuv")}"
    ENV.append "CPPFLAGS", "-I#{formula_opt_include("krb5")}"
    ENV.append "LDFLAGS", "-L#{formula_opt_lib("krb5")}"
    node_gyp = formula_opt_libexec("node")/"lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
    args = ["rebuild", "--nodedir=#{formula_opt_prefix("node")}"]

    cd(modules/"oracledb") { system "node", node_gyp, *args }
    cd modules/"kerberos" do
      # Upstream requests a universal binary on ARM; build for this machine only.
      inreplace "binding.gyp", '"-arch x86_64",', "" if OS.mac? && Hardware::CPU.arm?
      system "node", node_gyp, *args, "--kerberos_use_rtld=false"
    end
    if OS.mac?
      cd modules/"ibm_db" do
        ENV["IBM_DB_HOME"] = modules/"ibm_db/installer/clidriver"
        libdb2 = modules/"ibm_db/installer/clidriver/lib/libdb2.dylib"
        change_dylib_id libdb2, libdb2.to_s
        system "node", node_gyp, *args, "--IS_DOWNLOADED=true"
      end
    end

    (bin/"apifox").write_env_script libexec/"bin/cli.js", PATH: "#{formula_opt_bin("node")}:$PATH"
  end

  def caveats
    output = <<~EOS
      Oracle connections additionally require Oracle Instant Client for your architecture.
      Manage this installation with brew upgrade, rather than apifox update.
    EOS
    output += <<~EOS if OS.linux?
      Db2 connections are not included on Linux: IBM's client requires legacy libxml2.so.2.
    EOS
    output
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apifox --version")

    (testpath/"valid.json").write '{"method":"get","path":"/health"}'
    output = shell_output("#{bin}/apifox cli-schema validate endpoint-create --file #{testpath}/valid.json")
    assert_equal true, JSON.parse(output).dig("data", "valid")

    (testpath/"invalid.json").write '{"method":"invalid","path":"/health"}'
    output = shell_output("#{bin}/apifox cli-schema validate endpoint-create --file #{testpath}/invalid.json", 3)
    assert_equal "VALIDATION_FAILED", JSON.parse(output).dig("error", "code")

    (testpath/"native.js").write <<~JS
      const assert = require('node:assert/strict');
      const { createRequire } = require('node:module');
      const load = createRequire('#{libexec}/package.json');
      const fs = require('node:fs');
      const path = require('node:path');
      const root = '#{libexec}';
      const lock = load('./npm-shrinkwrap.json');
      for (const [name, entry] of Object.entries(lock.packages)) {
        if (!name) continue;
        const manifest = path.join(root, name, 'package.json');
        if (fs.existsSync(manifest)) {
          assert.equal(JSON.parse(fs.readFileSync(manifest)).version, entry.version, name);
        }
      }
      assert.equal(load('oracledb').versionString, '5.5.0');
      if (process.platform === 'darwin') {
        assert.equal(typeof load('ibm_db').open, 'function');
      } else {
        assert.throws(() => load.resolve('ibm_db'), { code: 'MODULE_NOT_FOUND' });
      }
      assert.equal(typeof load('kerberos').initializeClient, 'function');
      assert.equal(typeof load('ssh2').Client, 'function');
    JS
    system formula_opt_bin("node")/"node", testpath/"native.js"
  end
end
