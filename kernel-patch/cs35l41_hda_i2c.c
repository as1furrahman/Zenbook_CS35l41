// SPDX-License-Identifier: GPL-2.0
//
// CS35l41 HDA I2C driver
//
// Copyright 2021 Cirrus Logic, Inc.
//
// Author: Lucas Tanure <tanureal@opensource.cirrus.com>

#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/i2c.h>

#include "cs35l41_hda.h"

static unsigned int probe_retries = 30;
module_param(probe_retries, uint, 0444);
MODULE_PARM_DESC(probe_retries,
		 "Retries after a -ETIMEDOUT probe failure (default 15)");

static unsigned int probe_delay_ms = 3000;
module_param(probe_delay_ms, uint, 0444);
MODULE_PARM_DESC(probe_delay_ms,
		 "Delay between probe retries in ms (default 2000, linear spacing)");

static int cs35l41_hda_i2c_probe(struct i2c_client *clt)
{
	const char *device_name;
	struct regmap *regmap;
	unsigned int retry = 0;
	int ret;

	/*
	 * Compare against the device name so it works for SPI, normal ACPI
	 * and for ACPI by serial-multi-instantiate matching cases.
	 */
	if (strstr(dev_name(&clt->dev), "CLSA0100"))
		device_name = "CLSA0100";
	else if (strstr(dev_name(&clt->dev), "CLSA0101"))
		device_name = "CLSA0101";
	else if (strstr(dev_name(&clt->dev), "CSC3551"))
		device_name = "CSC3551";
	else
		return -ENODEV;

	/*
	 * Initialise the regmap once, outside the retry loop: devm resources
	 * from a failed cs35l41_hda_probe() call are not released until this
	 * probe function returns, so re-initialising inside the loop would
	 * stack redundant allocations.
	 */
	regmap = devm_regmap_init_i2c(clt, &cs35l41_regmap_i2c);
	if (IS_ERR(regmap))
		return PTR_ERR(regmap);

	/*
	 * On some laptops (e.g. ASUS Zenbook UM5302TA) the DesignWare I2C
	 * controller (AMDI0010) is not fully ready when the amps are first
	 * probed during boot, so the first attempt fails with -ETIMEDOUT
	 * while waiting for OTP_BOOT_DONE and the amps stay unbound for the
	 * whole boot. cs35l41_hda_probe() releases all resources on its
	 * error path (gpio, ACPI reference, allocations) and re-asserts the
	 * amp reset on entry, so it is safe to call again after a delay.
	 */
	for (;;) {
		ret = cs35l41_hda_probe(&clt->dev, device_name, clt->addr,
					clt->irq, regmap, I2C);
		if (ret != -ETIMEDOUT || retry >= probe_retries)
			return ret;

		retry++;
		/* On cold boot the amps can be in a state where the whole I2C
		 * bus segment times out (no ACK at all) until the device sees a
		 * power transition - the same reason a suspend/resume cycle
		 * fixes it. Cycle the ACPI power state of the amp the way PM
		 * would (D3cold -> D0) so any firmware-managed rail for this
		 * device gets re-initialised, then wait and try again.
		 * Linear spacing: the AMDI0010 controller can stay unusable for
		 * a long time after cold boot, so wait patiently. */
#ifdef CONFIG_ACPI
		{
			struct acpi_device *adev = ACPI_COMPANION(&clt->dev);

			if (adev) {
				acpi_device_set_power(adev, ACPI_STATE_D3_COLD);
				msleep(200);
				acpi_device_set_power(adev, ACPI_STATE_D0);
			}
		}
#endif
		msleep(probe_delay_ms);
		dev_warn(&clt->dev, "probe attempt %u failed with -ETIMEDOUT, retrying (%u/%u)\n",
			 retry, retry, probe_retries);
	}
}

static void cs35l41_hda_i2c_remove(struct i2c_client *clt)
{
	cs35l41_hda_remove(&clt->dev);
}

static const struct i2c_device_id cs35l41_hda_i2c_id[] = {
	{ "cs35l41-hda" },
	{}
};

static const struct acpi_device_id cs35l41_acpi_hda_match[] = {
	{"CLSA0100", 0 },
	{"CLSA0101", 0 },
	{"CSC3551", 0 },
	{}
};
MODULE_DEVICE_TABLE(acpi, cs35l41_acpi_hda_match);

static struct i2c_driver cs35l41_i2c_driver = {
	.driver = {
		.name		= "cs35l41-hda",
		.acpi_match_table = cs35l41_acpi_hda_match,
		.pm		= &cs35l41_hda_pm_ops,
	},
	.id_table	= cs35l41_hda_i2c_id,
	.probe		= cs35l41_hda_i2c_probe,
	.remove		= cs35l41_hda_i2c_remove,
};
module_i2c_driver(cs35l41_i2c_driver);

MODULE_DESCRIPTION("HDA CS35L41 driver");
MODULE_IMPORT_NS("SND_HDA_SCODEC_CS35L41");
MODULE_AUTHOR("Lucas Tanure <tanureal@opensource.cirrus.com>");
MODULE_LICENSE("GPL");
