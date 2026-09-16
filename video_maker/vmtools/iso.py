"""Write an mkpsxiso project XML and rebuild the ISO."""
import os
import subprocess

HEADER = """<iso_project image_name="{image}" cue_sheet="{cue}">
    <track type="data">
        <identifiers system="PLAYSTATION" application="PLAYSTATION" creation_date="1999112500000000+0"/>
        <license file="{license}"/>
        <default_attributes gmt_offs="36" xa_attrib="32" xa_perm="1365" xa_gid="0" xa_uid="0"/>
        <directory_tree gmt_offs="0">
"""
FOOTER = """        </directory_tree>
    </track>
</iso_project>
"""


def build_iso(sdk_path, workdir, xml_path, image, cue, license_file, files):
    """files: list of (iso_name, source_path, type)."""
    lines = [HEADER.format(image=image, cue=cue, license=license_file)]
    for name, src, typ in files:
        lines.append(f'            <file name="{name}" source="{src}" type="{typ}"/>\n')
    lines.append(FOOTER)
    with open(xml_path, "w", encoding="utf-8") as f:
        f.writelines(lines)

    mkpsxiso = os.path.join(sdk_path, "bin", "mkpsxiso.exe")
    out_bin = os.path.join(workdir, "output", image)
    out_cue = os.path.join(workdir, "output", cue)
    subprocess.run([mkpsxiso, xml_path, "-y", "-o", out_bin, "-c", out_cue],
                   check=True, cwd=workdir)
    return out_bin, out_cue
