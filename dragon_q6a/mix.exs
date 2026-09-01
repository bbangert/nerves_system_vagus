defmodule NervesSystemDragonQ6a.MixProject do
  use Mix.Project

  @github_organization "bbangert"
  @app :nerves_system_dragon_q6a
  @releases_repo "bbangert/nerves_system_vagus"
  @source_url "https://github.com/#{@releases_repo}"
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      # Because we're using OTP 27, we need to enforce Elixir 1.17 or later.
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: description(),
      package: package(),
      deps: deps(),
      aliases: [
        loadconfig: [&bootstrap/1]
      ],
      docs: docs()
    ]
  end

  def application do
    []
  end

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  def cli do
    [preferred_envs: %{docs: :docs, "hex.build": :docs, "hex.publish": :docs}]
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, @releases_repo}
      ],
      build_runner_opts: build_runner_opts(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      # The :env key is an optional experimental feature for adding environment
      # variables to the crosscompile environment. These are intended for
      # llvm-based tooling that may need more precise processor information.
      #
      # QCS6490 is a Cortex-A78 + Cortex-A55 big.LITTLE pair. GCC has no
      # combined -mcpu value for that pairing (verified against the 15.3
      # toolchain), so the generic armv8.2-a baseline is used instead of
      # pinning to one cluster.
      env: [
        {"TARGET_ARCH", "aarch64"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnu"},
        {"TARGET_GCC_FLAGS",
         "-mabi=lp64 -fstack-protector-strong -march=armv8.2-a -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: package_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.11", runtime: false},
      {:nerves_system_br, "1.34.0", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp description do
    """
    Nerves System - Radxa Dragon Q6A (QCS6490)
    """
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["GPL-2.0-only", "GPL-2.0-or-later"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  # NOTE: this list is the Nerves artifact checksum input (nerves_package's
  # :checksum above), not just the hex package manifest -- anything omitted
  # here does NOT invalidate a cached artifact when it changes.
  #
  # Still NOT covered (matches upstream nerves_system convention, but worth
  # knowing): mix.lock is unlisted, and deps float (e.g. the toolchain at
  # `~> 15.3.0`), so a dependency patch release can change the built output
  # without moving the artifact checksum.
  defp package_files do
    [
      "Config.in",
      "external.mk",
      "fwup_include",
      "package",
      "rootfs_overlay",
      "CHANGELOG.md",
      "fwup-ops.conf",
      "fwup.conf",
      "grub.cfg",
      "LICENSES/*",
      "linux-7.1.defconfig",
      "linux-bluetooth.config",
      "linux-containers.config",
      "linux-memory.config",
      "mix.exs",
      "nerves_defconfig",
      "patches",
      "post-build.sh",
      "post-createfs.sh",
      "README.md",
      "REUSE.toml",
      "VERSION"
    ]
  end

  defp build_runner_opts() do
    # Download source files first to get download errors right away.
    [make_args: primary_site() ++ ["source", "all", "legal-info"]]
  end

  defp primary_site() do
    case System.get_env("BR2_PRIMARY_SITE") do
      nil -> []
      primary_site -> ["BR2_PRIMARY_SITE=#{primary_site}"]
    end
  end

  defp set_target() do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end
