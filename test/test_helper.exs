ExUnit.start()

# The rule documents are published once, before the sandbox goes manual, so
# they are committed rows every test can see rather than fixtures every test
# has to build. Publishing one costs an xmllint spawn and a compile, which is
# not a thing to pay per test.
#
# Booking an appointment starts a visit process instance, so without this the
# scheduling suite could not book anything -- which is the wiring working, not
# a test-support workaround.
ClinicDemo.Rules.install!()

Ecto.Adapters.SQL.Sandbox.mode(ClinicDemo.Repo, :manual)
