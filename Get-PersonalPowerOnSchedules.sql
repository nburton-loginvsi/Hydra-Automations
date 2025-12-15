SELECT
    sh.AssignedUser,
    CASE
        WHEN JSON_VALUE(sh.Advanced, '$.AltVmResourceId') IS NULL THEN NULL
        ELSE RIGHT(
            JSON_VALUE(sh.Advanced, '$.AltVmResourceId'),
            CHARINDEX('/', REVERSE(JSON_VALUE(sh.Advanced, '$.AltVmResourceId'))) - 1
        )
    END AS machineName,
    CONVERT(varchar(5),
        DATEADD(minute, s.LocalTimeFrom, CAST('00:00:00' AS time)),
        108
    ) AS startTime,
    d.days
FROM dbo.SessionHosts sh
CROSS APPLY OPENJSON(sh.Advanced, '$.StartSchedules')
WITH (
    Enabled       bit '$.Enabled',
    LocalTimeFrom int '$.LocalTimeFrom',
    Mo bit '$.Weekdays.Mo',
    Tu bit '$.Weekdays.Tu',
    We bit '$.Weekdays.We',
    Th bit '$.Weekdays.Th',
    Fr bit '$.Weekdays.Fr',
    Sa bit '$.Weekdays.Sa',
    Su bit '$.Weekdays.Su'
) s
CROSS APPLY (
    SELECT STRING_AGG(v.DayName, ',') WITHIN GROUP (ORDER BY v.SortOrder) AS days
    FROM (VALUES
        (1, 'Mo', s.Mo),
        (2, 'Tu', s.Tu),
        (3, 'We', s.We),
        (4, 'Th', s.Th),
        (5, 'Fr', s.Fr),
        (6, 'Sa', s.Sa),
        (7, 'Su', s.Su)
    ) v(SortOrder, DayName, IsOn)
    WHERE v.IsOn = 1
) d
WHERE s.Enabled = 1;
