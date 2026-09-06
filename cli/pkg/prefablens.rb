class Prefablens < Formula
  desc "Semantic diff for UnityYAML assets"
  homepage "https://github.com/hashiiiii/PrefabLens"
  version "{{VERSION}}"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/hashiiiii/PrefabLens/releases/download/v#{version}/prefablens-macos-arm64.zip"
      sha256 "{{SHA256_MACOS_ARM64}}"
    end
    on_intel do
      url "https://github.com/hashiiiii/PrefabLens/releases/download/v#{version}/prefablens-macos-x64.zip"
      sha256 "{{SHA256_MACOS_X64}}"
    end
  end
  on_linux do
    on_intel do
      url "https://github.com/hashiiiii/PrefabLens/releases/download/v#{version}/prefablens-linux-x64.zip"
      sha256 "{{SHA256_LINUX_X64}}"
    end
  end

  def install
    bin.install "prefablens", "git-merge-prefablens"
  end

  test do
    assert_equal "prefablens #{version}\n", shell_output("#{bin}/prefablens --version")
    assert_equal "git-merge-prefablens #{version}\n", shell_output("#{bin}/git-merge-prefablens --version")
  end
end
