defmodule Eva.Extension.Memory.DistillerTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.Memory.Distiller

  describe "parse/1" do
    test "reads a clean array" do
      assert {:ok, [%{"fact" => "a"}]} = Distiller.parse(~s([{"fact": "a"}]))
    end

    test "reads through a code fence" do
      response = """
      ```json
      [{"fact": "the project uses Finch", "kind": "decision"}]
      ```
      """

      assert {:ok, [%{"fact" => "the project uses Finch"}]} = Distiller.parse(response)
    end

    test "reads through a preamble the model was asked not to write" do
      response = """
      Here are the durable facts I extracted:

      [{"fact": "extensions are namespaced Eva.Extension.<Name>"}]

      Let me know if you'd like more.
      """

      assert {:ok, [%{"fact" => fact}]} = Distiller.parse(response)
      assert fact =~ "namespaced"
    end

    test "an empty array is a valid, expected answer" do
      assert {:ok, []} = Distiller.parse("[]")
      assert {:ok, []} = Distiller.parse("Nothing durable here.\n\n[]")
    end

    test "drops entries with no usable fact rather than storing blanks" do
      response = ~s([{"fact": "real"}, {"kind": "decision"}, {"fact": "   "}])

      assert {:ok, [%{"fact" => "real"}]} = Distiller.parse(response)
    end

    test "reports unparseable output instead of guessing" do
      assert {:error, {:unparseable, _}} = Distiller.parse("I could not find anything.")
      assert {:error, {:unparseable, _}} = Distiller.parse("[{broken")
    end
  end
end
