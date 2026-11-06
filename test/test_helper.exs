# The real-solver tests need MiniZinc on the PATH; without it they are skipped, and the
# scripted-backend tests still cover the whole pipeline.
solver_tag = if System.find_executable("minizinc"), do: [], else: [:solver]

ExUnit.start(exclude: solver_tag)

# The rule documents are published once, before the sandbox goes manual, so
# they are committed rows every test can see rather than fixtures every test
# has to build. Publishing one costs an xmllint spawn and a compile, which is
# not a thing to pay per test.
#
# Booking an appointment starts a visit process instance, so without this the
# scheduling suite could not book anything -- which is the wiring working, not
# a test-support workaround.
ClinicDemo.Rules.install!()

# The weekly roster model is published and bound once for the same reason: its
# ModelVersion and Binding are committed rows every planning test can see.
ClinicDemo.Planning.Install.install!()

Ecto.Adapters.SQL.Sandbox.mode(ClinicDemo.Repo, :manual)
