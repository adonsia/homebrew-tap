class ApifoxCli < Formula
  desc "Official Apifox CLI for API documentation and testing"
  homepage "https://apifox.com/apifox-cli/"
  url "https://registry.npmjs.org/apifox-cli/-/apifox-cli-2.2.12.tgz"
  sha256 "7b5866bab0c6d8c882dcafbbfe7da4de827547dec2a6beff1663526baf40cb53"
  license :cannot_represent

  depends_on "node"

  resource "npm-shrinkwrap" do
    url "https://github.com/adonsia/homebrew-tap/releases/download/apifox-cli-2.2.12/npm-shrinkwrap.json"
    sha256 "4d5209eaa864f41be2682012333315eda082aa81692d9acde4a3f77b0dce468e"
  end

  def install
    resource("npm-shrinkwrap").stage { buildpath.install "npm-shrinkwrap.json" }
    # Optional database/authentication addons are unnecessary for API workflows.
    system "npm", "ci", *std_npm_args(prefix: false), "--omit=dev", "--omit=optional"
    libexec.install Dir["*"]

    (bin/"apifox").write_env_script libexec/"bin/cli.js", PATH: "#{formula_opt_bin("node")}:$PATH"
  end

  def caveats
    <<~EOS
      Optional Oracle, Db2 and Kerberos integrations are not included.
      Manage this installation with brew upgrade, rather than apifox update.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apifox --version")

    (testpath/"valid.json").write '{"method":"get","path":"/health"}'
    output = shell_output("#{bin}/apifox cli-schema validate endpoint-create --file #{testpath}/valid.json")
    assert_equal true, JSON.parse(output).dig("data", "valid")

    (testpath/"invalid.json").write '{"method":"invalid","path":"/health"}'
    output = shell_output("#{bin}/apifox cli-schema validate endpoint-create --file #{testpath}/invalid.json", 3)
    assert_equal "VALIDATION_FAILED", JSON.parse(output).dig("error", "code")

    (testpath/"dependencies.js").write <<~JS
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
      for (const name of ['oracledb', 'ibm_db', 'kerberos']) {
        assert.throws(() => load.resolve(name), { code: 'MODULE_NOT_FOUND' });
      }
      assert.equal(typeof load('ssh2').Client, 'function');
    JS
    system formula_opt_bin("node")/"node", testpath/"dependencies.js"
  end
end
