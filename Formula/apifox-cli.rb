class ApifoxCli < Formula
  desc "Official Apifox CLI for API documentation and testing"
  homepage "https://apifox.com/apifox-cli/"
  url "https://registry.npmjs.org/apifox-cli/-/apifox-cli-2.2.11.tgz"
  sha256 "4d0dd00f14329b6a2f1a35c693c121cc6da26fe4fa9c357fe870dde8b1e0ac39"
  license :cannot_represent

  depends_on "node@24"

  def install
    system "npm", "install", *std_npm_args, "--omit=dev"
    bin.mkpath
    (bin/"apifox").write_env_script libexec/"bin/apifox", PATH: "#{Formula["node@24"].opt_bin}:$PATH"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apifox --version")
    assert_match "import", shell_output("#{bin}/apifox --help")
  end
end
