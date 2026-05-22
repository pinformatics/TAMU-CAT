# Faculty Export Preparation Guide

## Purpose

Use this guide when preparing files for course competency imports.

The system supports Canvas-generated competency exports and a simpler faculty template.

## Faculty Template Format

Use this header structure:

```text
Student name,Student UIN,[Competency Title] COURSE TARGET,[Competency Title] ASSESSED LEVEL
```

Repeat the `COURSE TARGET` and `ASSESSED LEVEL` pair for each competency covered by the course.

Example:

```text
Student name,Student UIN,Public and Population Health Assessment COURSE TARGET,Public and Population Health Assessment ASSESSED LEVEL
```

## Required Student Fields

- `Student name`
- `Student UIN`

The UIN must be exactly 9 digits. Blank or invalid UINs are treated as import errors unless the workflow intentionally uses pending student matching.

## Required Competency Fields

Each competency should have:

- `[Competency Title] COURSE TARGET`
- `[Competency Title] ASSESSED LEVEL`

Values must be whole numbers from 1 through 5.

Blank assessed or target cells should be left truly blank. Do not enter placeholders such as `N/A`, `as`, `d`, or `-99`.

## Course Target vs Assessed Level

- `COURSE TARGET` is the expected level for the course.
- `ASSESSED LEVEL` is the student's actual assessed level from the course.

These are course-level values. They are not the same as end-of-program targets configured in the admin setup.

## Competency Names

Use the competency titles provided in the curriculum catalog or template.

If a title varies from the master lookup table, the import will report a missing competency mapping. Admins can add approved aliases to [db/data/competency_aliases.csv](../db/data/competency_aliases.csv).

## File Naming

Use a clear course code in the file name:

```text
Outcomes-26S-PHPM-601.csv
```

The importer uses file and sheet names to help derive course codes.

## Before Sending the File

Check:

- the course code is correct
- student UINs are 9 digits
- no real student data is included in sample/template files
- every competency has a course target column and assessed level column
- numeric cells contain only 1, 2, 3, 4, or 5
- blank cells are intentional
- the file is saved as CSV or Excel
