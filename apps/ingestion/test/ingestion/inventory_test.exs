defmodule Ingestion.InventoryTest do
  use Ingestion.DataCase, async: true

  import Ingestion.Fixtures

  alias Ingestion.Inventory
  alias Ingestion.Inventory.SeedData

  describe "seed_real_inventory!/0" do
    setup do
      {zones, sensors} = Inventory.seed_real_inventory!()
      %{zone_count: zones, sensor_count: sensors}
    end

    test "seeds all 16 zones and 56 sensors", ctx do
      assert ctx.zone_count == 16
      assert ctx.sensor_count == 56

      assert length(Inventory.list_zones()) == 16
      assert length(Inventory.list_sensors()) == 56
    end

    test "every sensor has a unique, non-nil serial" do
      serials = Inventory.list_sensors() |> Enum.map(& &1.serial)

      assert length(serials) == 56
      assert Enum.uniq(serials) |> length() == 56
      refute Enum.any?(serials, &is_nil/1)
    end

    test "is idempotent — re-running does not duplicate anything" do
      {zones, sensors} = Inventory.seed_real_inventory!()

      assert {zones, sensors} == {16, 56}
      assert length(Inventory.list_sensors()) == 56
    end

    test "preserves the Store3-FL duplicate display name rather than renaming it" do
      duplicates =
        Inventory.list_sensors()
        |> Enum.filter(&(&1.name == "keMSAsoStore3-FL"))

      assert length(duplicates) == 2

      serials = duplicates |> Enum.map(& &1.serial) |> Enum.sort()
      assert serials == ["Q3CQ-96DA-V53R", "Q3CQ-EBP3-FCM5"]
    end

    test "preserves Store11's missing RR corner as a genuine coverage gap" do
      positions = zone_positions("Store11")

      assert Enum.sort(positions) == ["FL", "FR", "RL"]
      refute "RR" in positions
    end

    test "preserves Store13's single whole-zone sensor" do
      assert zone_positions("Store13") == ["single"]
    end

    test "preserves Store14's numeric position naming" do
      assert Enum.sort(zone_positions("Store14")) == ["01", "02", "03", "04"]
    end

    test "flags Store10-RL as non-conforming without making it an environmental anomaly" do
      sensor = Inventory.get_sensor_by_serial("Q3CQ-9M7Z-WPDT")

      assert sensor.name == "keMSAsoStore10-RL"
      assert sensor.meraki_status == "non_conforming"

      # Device-health flag only: it stays a normal, in-scope storage sensor.
      assert sensor.zone.zone_type == "storage"
      assert Inventory.food_safety_scope?(sensor)

      assert Enum.map(Inventory.list_flagged_sensors(), & &1.serial) == ["Q3CQ-9M7Z-WPDT"]
    end

    test "seeds the single sitewide water sensor at the entry point" do
      water = Inventory.list_sensors() |> Enum.filter(&(&1.sensor_type == "water"))

      assert [sensor] = water
      assert sensor.serial == "Q3CB-9N4K-D33G"
      assert sensor.model == "MT12"
      assert sensor.zone.name == "SE"
    end

    test "records known battery levels and leaves unknown ones nil, never zero" do
      assert Inventory.get_sensor_by_serial("Q3CB-9N4K-D33G").battery_pct == 65
      assert Inventory.get_sensor_by_serial("Q3CG-VAYR-FHQE").battery_pct == 29

      unknown = Inventory.get_sensor_by_serial("Q3CQ-4Y5F-59LL")
      assert unknown.battery_pct == nil
      assert unknown.rssi_dbm == nil
    end

    test "invents no commodity for any zone" do
      assert Enum.all?(Inventory.list_zones(), &is_nil(&1.commodity))
    end

    test "excludes both server rooms and the entry point from food-safety scope" do
      srv = Inventory.get_zone_by_name("SRV")
      se = Inventory.get_zone_by_name("SE")

      assert srv.zone_type == "server_room"
      assert se.zone_type == "entry_point"

      refute Inventory.food_safety_scope?(srv)
      refute Inventory.food_safety_scope?(se)

      # And every sensor in them is out of scope too.
      out_of_scope =
        Inventory.list_sensors()
        |> Enum.filter(&(&1.zone.name in ["SRV", "SE"]))

      assert length(out_of_scope) == 4
      refute Enum.any?(out_of_scope, &Inventory.food_safety_scope?/1)
    end

    test "food-safety zones are exactly the 14 storage stores" do
      names = Inventory.list_food_safety_zones() |> Enum.map(& &1.name)

      assert length(names) == 14
      refute "SRV" in names
      refute "SE" in names
    end

    defp zone_positions(zone_name) do
      Inventory.list_sensors()
      |> Enum.filter(&(&1.zone.name == zone_name))
      |> Enum.map(& &1.position)
    end
  end

  describe "SeedData integrity (independent of the database)" do
    test "declares 16 zones and 56 sensors" do
      assert length(SeedData.zones()) == 16
      assert length(SeedData.sensors()) == 56
    end

    test "every declared sensor points at a declared zone" do
      zone_names = SeedData.zones() |> MapSet.new(& &1.name)

      Enum.each(SeedData.sensors(), fn sensor ->
        assert MapSet.member?(zone_names, sensor.zone_name),
               "sensor #{sensor.serial} references unknown zone #{sensor.zone_name}"
      end)
    end
  end

  describe "evaluable?/1" do
    test "a storage zone with a confirmed commodity is evaluable" do
      zone = insert_zone!(%{zone_type: "storage", commodity: "frozen_food"})
      assert Inventory.evaluable?(zone)
    end

    test "a storage zone without a confirmed commodity is in scope but not yet evaluable" do
      zone = insert_zone!(%{zone_type: "storage", commodity: nil})

      assert Inventory.food_safety_scope?(zone)
      refute Inventory.evaluable?(zone)
    end

    test "a server room is never evaluable, even if a commodity were set on it" do
      zone = insert_zone!(%{zone_type: "server_room", commodity: "frozen_food"})

      refute Inventory.food_safety_scope?(zone)
      refute Inventory.evaluable?(zone)
    end

    test "an entry point is never evaluable" do
      zone = insert_zone!(%{zone_type: "entry_point", commodity: "frozen_food"})
      refute Inventory.evaluable?(zone)
    end
  end
end
